// NDJSON v1 frames shared by the scheduler and the sandbox runner.
// Mirrors docs/plans/sandbox-architecture.md §5.7.3 and the Haskell module
// Infrastructure.Sandbox.Protocol; keep both sides in sync.

export const PROTOCOL_VERSION = 1;
export const MAX_FRAME_BYTES = 1024 * 1024;

export type FrameOp =
  | 'hello' | 'ready' | 'exec' | 'stdin' | 'stdout' | 'stderr'
  | 'exit' | 'deny' | 'probe' | 'audit' | 'error' | 'shutdown';

export interface BaseFrame {
  v: number;
  op: FrameOp;
}

export interface HelloFrame extends BaseFrame {
  op: 'hello';
  scope: string;
  parent?: string;
  policy: string;
  isolation: string;
}

export interface ReadyFrame extends BaseFrame {
  op: 'ready';
  backend: string;
  enforcement: 'full' | 'partial' | 'none';
  capabilities: Record<string, unknown>;
  pid: number;
}

export interface ExecFrame extends BaseFrame {
  op: 'exec';
  id: string;
  argv: string[];
  cwd: string;
  env?: Array<{ name: string; value: string }>;
  stdin?: string;
  timeoutMs?: number;
}

export interface StdinFrame extends BaseFrame { op: 'stdin'; id: string; data: string }
export interface OutputFrame extends BaseFrame { op: 'stdout' | 'stderr'; id: string; data: string }

export interface ExitFrame extends BaseFrame {
  op: 'exit';
  id: string;
  code: number;
  signal?: string;
}

export interface DenyFrame extends BaseFrame {
  op: 'deny';
  id: string;
  kind: 'fs-read' | 'fs-write' | 'net' | 'syscall' | 'exec';
  target: string;
}

export interface ErrorFrame extends BaseFrame {
  op: 'error';
  id?: string;
  code: 'protocol' | 'policy' | 'backend' | 'limit';
  message: string;
}

export interface ShutdownFrame extends BaseFrame { op: 'shutdown' }

export type Frame =
  | HelloFrame | ReadyFrame | ExecFrame | StdinFrame | OutputFrame
  | ExitFrame | DenyFrame | ErrorFrame | ShutdownFrame;

export class SandboxProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SandboxProtocolError';
  }
}

export function encodeFrame(frame: Frame): string {
  return JSON.stringify({ ...frame, v: PROTOCOL_VERSION }) + '\n';
}

const VALID_OPS: ReadonlySet<string> = new Set<FrameOp>([
  'hello', 'ready', 'exec', 'stdin', 'stdout', 'stderr',
  'exit', 'deny', 'probe', 'audit', 'error', 'shutdown',
]);

export function decodeFrame(line: string): Frame {
  if (Buffer.byteLength(line, 'utf8') > MAX_FRAME_BYTES) {
    throw new SandboxProtocolError(`frame exceeds ${MAX_FRAME_BYTES} bytes`);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch (e) {
    throw new SandboxProtocolError(`malformed frame: ${(e as Error).message}`);
  }
  if (!parsed || typeof parsed !== 'object') {
    throw new SandboxProtocolError('frame must be an object');
  }
  const frame = parsed as Partial<BaseFrame>;
  if (frame.v !== PROTOCOL_VERSION) {
    throw new SandboxProtocolError(`version mismatch: ${String(frame.v)}`);
  }
  if (typeof frame.op !== 'string') {
    throw new SandboxProtocolError('frame is missing op');
  }
  if (!VALID_OPS.has(frame.op)) {
    throw new SandboxProtocolError(`unknown op: ${frame.op}`);
  }
  return frame as Frame;
}
