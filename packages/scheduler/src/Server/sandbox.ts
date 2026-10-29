// Sandbox seam for the scheduler (docs/plans/sandbox-architecture.md §5.7.4).
//
// Compatibility default (ADR: user choice A): TRHA_SANDBOX=off means the
// existing unconfined path is used and this module is never called. Setting
// TRHA_SANDBOX=on routes shell execution through `trha sandbox runner` over
// NDJSON v1. A runner failure is a failed tool call — never a silent fallback.

import { spawn, execFile } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { PROTOCOL_VERSION, decodeFrame, encodeFrame, type ExecFrame, type Frame, type HelloFrame, type StdinFrame } from './sandboxProtocol.js';

export type SandboxIsolation = 'shared' | 'process' | 'strong' | 'remote';

export type NetworkPolicy =
  | { kind: 'off' }
  | { kind: 'allow'; domains: string[] }
  | { kind: 'proxy'; url: string };

export interface ResourceLimits {
  pids?: number;
  memoryMiB?: number;
  wallMs?: number;
}

export type SandboxPolicy =
  | { kind: 'read-only'; readonlyRoots?: string[]; network?: NetworkPolicy }
  | {
      kind: 'workspace-write';
      root: string;
      readonlyRoots?: string[];
      network?: NetworkPolicy;
      limits?: ResourceLimits;
    }
  | { kind: 'danger-full-access' };

export interface SandboxScope {
  id: string;
  parent?: string;
  policy: SandboxPolicy;
  isolation: SandboxIsolation;
  scratch: string;
}

export interface SandboxRequest {
  argv: string[];
  cwd: string;
  env?: Record<string, string>;
  stdin?: string;
  timeoutMs?: number;
  /** Audit tag (batch:variant:seed) passed to the runner. */
  experiment?: string;
}

export type SandboxDenialKind = 'fs-read' | 'fs-write' | 'net' | 'syscall' | 'exec';

export interface SandboxDenial {
  kind: SandboxDenialKind;
  target: string;
}

export interface SandboxResult {
  ok: boolean;
  enforcement: 'full' | 'partial' | 'none';
  partialReasons?: string[];
  code: number | null;
  signal?: string;
  stdout: string;
  stderr: string;
  denials: SandboxDenial[];
}

export type SandboxCapability =
  | 'fs-read' | 'fs-write' | 'net' | 'pid' | 'syscall' | 'resource' | 'cred';

export interface SandboxCapabilities {
  landlock?: number;
  seccomp?: boolean;
  netns?: boolean;
  userns?: boolean;
  capsicum?: boolean;
  pledge?: boolean;
  restrictedToken?: boolean;
  appContainer?: boolean;
  jobObject?: boolean;
}

export type SandboxPlatform =
  | 'linux' | 'freebsd' | 'openbsd' | 'darwin' | 'win32' | 'android' | 'other';

export interface SandboxStatus {
  backend: string;
  platform: SandboxPlatform;
  enforcement: 'full' | 'partial' | 'none';
  available: boolean;
  capabilities: SandboxCapabilities;
  missing?: SandboxCapability[];
  notes?: string[];
}

export interface ProbeResult {
  name: string;
  ok: boolean;
  expected: string;
  actual: string;
}

export class SandboxUnavailableError extends Error {
  readonly backend: string;

  constructor(backend: string, message: string) {
    super(message);
    this.name = 'SandboxUnavailableError';
    this.backend = backend;
  }
}

let runtimeEnabled: boolean | undefined;
let cachedConfig: SandboxConfigView | undefined;

/** Runtime override set by PUT /api/sandbox/config (survives until restart). */
export function setSandboxEnabledRuntime(on: boolean | undefined): void {
  runtimeEnabled = on;
}

/** Cache the last known config so scopes use the tuned policy/scratch. */
export function setSandboxConfigRuntime(cfg: SandboxConfigView | undefined): void {
  cachedConfig = cfg;
}

/** Compatibility default: only an explicit on/true/1/enforce enables the seam. */
export function sandboxEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  if (runtimeEnabled !== undefined) return runtimeEnabled;
  const raw = (env.TRHA_SANDBOX ?? 'off').trim().toLowerCase();
  return !(raw === '' || raw === 'off' || raw === 'false' || raw === '0' || raw === 'disabled');
}

function runnerCommand(): string {
  return process.env.TRHA_SANDBOX_RUNNER ?? 'trha';
}

export interface SandboxConfigView {
  enabled: boolean;
  policy: string;
  network: string;
  scratch: string;
}

/** Read ~/.trha/sandbox.yaml through the CLI (single writer/parser). */
export async function readSandboxConfig(): Promise<SandboxConfigView> {
  const { stdout } = await execFileAsync(runnerCommand(), ['sandbox', 'config', '--json'], {
    timeout: 5000,
    env: process.env,
  });
  const parsed = JSON.parse(stdout) as Partial<SandboxConfigView>;
  const view: SandboxConfigView = {
    enabled: parsed.enabled ?? false,
    policy: parsed.policy ?? 'workspace-write',
    network: parsed.network ?? 'off',
    scratch: parsed.scratch ?? '~/.trha/sandbox-scratch',
  };
  cachedConfig = view;
  return view;
}

/** Persist a config patch via the CLI and apply the enable flag immediately. */
export async function writeSandboxConfig(
  patch: Partial<SandboxConfigView>,
): Promise<SandboxConfigView> {
  const args = ['sandbox', 'config'];
  if (typeof patch.enabled === 'boolean') args.push('--enabled', patch.enabled ? 'on' : 'off');
  if (patch.policy) args.push('--policy', patch.policy);
  if (patch.network) args.push('--network', patch.network);
  if (patch.scratch) args.push('--scratch', patch.scratch);
  args.push('--json');
  const { stdout } = await execFileAsync(runnerCommand(), args, {
    timeout: 5000,
    env: process.env,
  });
  const parsed = JSON.parse(stdout) as SandboxConfigView;
  cachedConfig = parsed;
  if (typeof patch.enabled === 'boolean') setSandboxEnabledRuntime(patch.enabled);
  return parsed;
}

function currentPlatform(): SandboxPlatform {
  switch (process.platform) {
    case 'linux': return 'linux';
    case 'freebsd': return 'freebsd';
    case 'openbsd': return 'openbsd';
    case 'darwin': return 'darwin';
    case 'win32': return 'win32';
    case 'android': return 'android';
    default: return 'other';
  }
}

function parseNetworkSpec(raw: string | undefined): NetworkPolicy {
  const t = (raw ?? 'off').trim();
  if (t.startsWith('allow:')) {
    return {
      kind: 'allow',
      domains: t.slice(6).split(',').map(x => x.trim()).filter(Boolean),
    };
  }
  if (t.startsWith('proxy:')) return { kind: 'proxy', url: t.slice(6) };
  return { kind: 'off' };
}

function networkSpecText(policy: SandboxPolicy): string {
  if (policy.kind !== 'workspace-write' || !policy.network) return 'off';
  const n = policy.network;
  if (n.kind === 'allow') return `allow:${n.domains.join(',')}`;
  if (n.kind === 'proxy') return `proxy:${n.url}`;
  return 'off';
}

function policyName(policy: SandboxPolicy): string {
  return policy.kind === 'read-only' ? 'read-only' : 'workspace-write';
}

function workspaceFor(scope: SandboxScope, request: SandboxRequest): string {
  if (scope.policy.kind === 'workspace-write') return scope.policy.root;
  return request.cwd;
}

/** Scope used by the scheduler when only cwd/policy env vars are available. */
export function defaultSandboxScope(
  cwd: string,
  env: NodeJS.ProcessEnv = process.env,
): SandboxScope {
  const kind = (cachedConfig?.policy ?? env.TRHA_SANDBOX_POLICY ?? 'workspace-write')
    .trim()
    .toLowerCase();
  const configured = cachedConfig?.scratch ?? env.TRHA_SANDBOX_SCRATCH;
  const scratch = configured
    ? (configured.startsWith('~/')
        ? path.join(os.homedir(), configured.slice(2))
        : configured)
    : path.join(os.homedir(), '.trha', 'sandbox-scratch');
  const network = parseNetworkSpec(
    cachedConfig?.network ?? env.TRHA_SANDBOX_NETWORK ?? 'off',
  );
  const policy: SandboxPolicy = kind === 'read-only'
    ? { kind: 'read-only', readonlyRoots: [cwd], network }
    : { kind: 'workspace-write', root: cwd, network };
  return {
    id: env.TRHA_SANDBOX_SCOPE ?? 'scheduler',
    policy,
    isolation: 'process',
    scratch,
  };
}

const policies = new Map<string, SandboxPolicy>();

const execFileAsync = promisify(execFile);

/** Report the seam state. When enabled, ask the runner for the real backend. */
export async function sandboxStatus(): Promise<SandboxStatus> {
  if (!sandboxEnabled()) {
    return {
      backend: 'none',
      platform: currentPlatform(),
      enforcement: 'none',
      available: false,
      capabilities: {},
      missing: ['fs-read', 'fs-write', 'net', 'syscall', 'resource', 'cred'],
      notes: ['TRHA_SANDBOX is off (compatibility default)'],
    };
  }
  try {
    const { stdout } = await execFileAsync(runnerCommand(), ['sandbox', 'status', '--json'], {
      timeout: 5000,
      env: process.env,
    });
    const parsed = JSON.parse(stdout) as Partial<SandboxStatus>;
    return {
      backend: parsed.backend ?? 'none',
      platform: parsed.platform ?? currentPlatform(),
      enforcement: parsed.enforcement ?? 'none',
      available: parsed.available ?? false,
      capabilities: parsed.capabilities ?? {},
      ...(parsed.missing ? { missing: parsed.missing } : {}),
      ...(parsed.notes ? { notes: parsed.notes } : {}),
    };
  } catch (e) {
    return {
      backend: 'none',
      platform: currentPlatform(),
      enforcement: 'none',
      available: false,
      capabilities: {},
      notes: [(e as Error).message],
    };
  }
}

/** Run one command through the runner. Throws instead of running unconfined. */
export async function sandboxedSpawn(
  scope: SandboxScope,
  request: SandboxRequest,
): Promise<SandboxResult> {
  if (!sandboxEnabled()) {
    throw new SandboxUnavailableError(
      'disabled',
      'TRHA_SANDBOX is off; refusing to run through the sandbox seam',
    );
  }
  if (scope.policy.kind === 'danger-full-access') {
    throw new SandboxUnavailableError('policy', 'danger-full-access must not be rendered');
  }
  const runner = process.env.TRHA_SANDBOX_RUNNER ?? 'trha';
  // The scratch bind source must exist before bwrap mounts it.
  mkdirSync(scope.scratch, { recursive: true, mode: 0o700 });
  const args = [
    'sandbox', 'runner',
    '--workspace', workspaceFor(scope, request),
    '--scratch', scope.scratch,
    '--policy', policyName(scope.policy),
    '--network', networkSpecText(scope.policy),
    ...(request.experiment ? ['--experiment', request.experiment] : []),
  ];
  const child = spawn(runner, args, { stdio: ['pipe', 'pipe', 'pipe'] });
  // Preserve the caller's PATH so host toolchains (ghcup/cabal/fnm) remain
  // reachable; the runner still filters credentials and sets HOME.  HOME is
  // passed as a *hint only*: the renderer turns it into XDG_STATE_HOME etc.
  // (host package store, read-only) before HOME is pointed at scratch.
  const withEnv: SandboxRequest = {
    ...request,
    env: {
      PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
      HOME: process.env.HOME ?? os.homedir(),
      ...request.env,
    },
  };
  return exchange(child, scope, withEnv);
}

/** A long-lived sandboxed child (persistent shell) driven by the caller. */
export type SandboxSession = {
  /** Exec id on the wire; also the audit correlation id. */
  id: string;
  /** Feed bytes to the child's stdin. */
  write(data: string): void;
  /** Terminate the runner (and with it the sandboxed child). */
  kill(): void;
  /** Every stdout/stderr chunk, plus rendered deny frames. */
  onData(cb: (chunk: string) => void): void;
  /** Fires once, on child exit or runner failure. */
  onExit(cb: (code: number) => void): void;
};

/**
 * Start a long-lived child inside the sandbox and keep it interactive.
 *
 * `sandboxedSpawn` resolves once the exit frame arrives; this variant hands
 * back a session as soon as the runner says `ready`, which is what a
 * persistent shell (`terminal_open`) needs. The runner waits for its child on
 * a separate thread, so stdin frames keep flowing while it runs.
 */
export async function sandboxedInteractive(
  scope: SandboxScope,
  request: SandboxRequest,
): Promise<SandboxSession> {
  if (!sandboxEnabled()) {
    throw new SandboxUnavailableError(
      'disabled',
      'TRHA_SANDBOX is off; refusing to run through the sandbox seam',
    );
  }
  if (scope.policy.kind === 'danger-full-access') {
    throw new SandboxUnavailableError('policy', 'danger-full-access must not be rendered');
  }
  const runner = process.env.TRHA_SANDBOX_RUNNER ?? 'trha';
  mkdirSync(scope.scratch, { recursive: true, mode: 0o700 });
  const args = [
    'sandbox', 'runner',
    '--workspace', workspaceFor(scope, request),
    '--scratch', scope.scratch,
    '--policy', policyName(scope.policy),
    '--network', networkSpecText(scope.policy),
    ...(request.experiment ? ['--experiment', request.experiment] : []),
  ];
  const child = spawn(runner, args, { stdio: ['pipe', 'pipe', 'pipe'] });
  const id = 'i1';
  const dataHandlers: Array<(chunk: string) => void> = [];
  const exitHandlers: Array<(code: number) => void> = [];
  let exited = false;
  const emit = (chunk: string): void => {
    for (const cb of dataHandlers) cb(chunk);
  };
  const finish = (code: number): void => {
    if (exited) return;
    exited = true;
    for (const cb of exitHandlers) cb(code);
  };
  if (!child.stdin || !child.stdout || !child.stderr) {
    child.kill();
    throw new SandboxUnavailableError('runner', 'runner has no stdio pipes');
  }
  const stdin = child.stdin;
  const envPairs = Object.entries({
    PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
    HOME: process.env.HOME ?? os.homedir(),
    ...request.env,
  }).map(([name, value]) => ({ name, value }));

  const ready = new Promise<void>((resolve, reject) => {
    let buffer = '';
    child.stdout!.setEncoding('utf8');
    child.stdout!.on('data', (chunk: string) => {
      buffer += chunk;
      for (;;) {
        const nl = buffer.indexOf('\n');
        if (nl < 0) return;
        const line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        if (!line.trim()) continue;
        let frame: Frame;
        try {
          frame = decodeFrame(line);
        } catch (e) {
          reject(e);
          child.kill();
          return;
        }
        switch (frame.op) {
          case 'ready': {
            const execFrame = {
              v: PROTOCOL_VERSION,
              op: 'exec',
              id,
              argv: request.argv,
              cwd: request.cwd,
              ...(envPairs.length ? { env: envPairs } : {}),
              ...(request.timeoutMs !== undefined ? { timeoutMs: request.timeoutMs } : {}),
            } as ExecFrame;
            stdin.write(encodeFrame(execFrame));
            resolve();
            break;
          }
          case 'stdout':
          case 'stderr':
            emit(frame.data);
            break;
          case 'deny':
            emit(`\n[sandbox denied ${frame.kind}: ${frame.target}]\n`);
            break;
          case 'exit':
            finish(frame.code);
            break;
          case 'error':
            emit(`ERROR: ${frame.message}\n`);
            finish(-1);
            break;
          default:
            break;
        }
      }
    });
  });
  child.stderr.setEncoding('utf8');
  // Runner diagnostics only: the child's own stderr arrives as frames.
  child.stderr.on('data', () => {});
  child.on('error', () => finish(-1));
  child.on('exit', () => finish(-1));

  const helloFrame: HelloFrame = {
    v: PROTOCOL_VERSION,
    op: 'hello',
    scope: scope.id,
    ...(scope.parent !== undefined ? { parent: scope.parent } : {}),
    policy: policyName(scope.policy),
    isolation: scope.isolation,
  };
  stdin.write(encodeFrame(helloFrame));
  await ready;

  return {
    id,
    write(data: string): void {
      if (exited) return;
      stdin.write(encodeFrame({ v: PROTOCOL_VERSION, op: 'stdin', id, data } as StdinFrame));
    },
    kill(): void {
      child.kill('SIGTERM');
      const t = setTimeout(() => child.kill('SIGKILL'), 1000);
      if (typeof t.unref === 'function') t.unref();
    },
    onData(cb: (chunk: string) => void): void {
      dataHandlers.push(cb);
    },
    onExit(cb: (code: number) => void): void {
      exitHandlers.push(cb);
    },
  };
}

function exchange(
  child: ReturnType<typeof spawn>,
  scope: SandboxScope,
  request: SandboxRequest,
): Promise<SandboxResult> {
  return new Promise((resolve, reject) => {
    let buffer = '';
    let stdout = '';
    let stderr = '';
    let enforcement: SandboxResult['enforcement'] = 'full';
    let finished = false;
    const denials: SandboxDenial[] = [];
    const timeoutMs = request.timeoutMs ?? 600_000;
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      settle(() => reject(new SandboxUnavailableError('timeout', `sandbox runner exceeded ${timeoutMs} ms`)));
    }, timeoutMs);

    function settle(action: () => void): void {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      action();
    }

    if (!child.stdout || !child.stderr || !child.stdin) {
      settle(() => reject(new SandboxUnavailableError('runner', 'runner has no stdio pipes')));
      child.kill();
      return;
    }
    const stdin = child.stdin;
    const stdoutStream = child.stdout;
    const stderrStream = child.stderr;
    stdoutStream.setEncoding('utf8');
    stderrStream.setEncoding('utf8');

    stderrStream.on('data', (chunk: string) => { stderr += chunk; });
    child.on('error', (e) => {
      settle(() => reject(new SandboxUnavailableError('runner', e.message)));
    });
    child.on('exit', (exitCode) => {
      if (!finished) {
        settle(() => reject(new SandboxUnavailableError(
          'runner',
          `runner exited (${exitCode ?? 'signal'}) without an exit frame`,
        )));
      }
    });

    stdoutStream.on('data', (chunk: string) => {
      buffer += chunk;
      for (;;) {
        const newline = buffer.indexOf('\n');
        if (newline < 0) return;
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (!line.trim()) continue;
        let frame: Frame;
        try {
          frame = decodeFrame(line);
        } catch (e) {
          settle(() => reject(e));
          child.kill();
          return;
        }
        switch (frame.op) {
          case 'ready': {
            enforcement = frame.enforcement;
            const execFrame: ExecFrame = {
              v: PROTOCOL_VERSION,
              op: 'exec',
              id: 'c1',
              argv: request.argv,
              cwd: request.cwd,
              ...(request.env
                ? { env: Object.entries(request.env).map(([name, value]) => ({ name, value })) }
                : {}),
              ...(request.stdin !== undefined ? { stdin: request.stdin } : {}),
              ...(request.timeoutMs !== undefined ? { timeoutMs: request.timeoutMs } : {}),
            };
            stdin.write(encodeFrame(execFrame));
            break;
          }
          case 'stdout':
            stdout += frame.data;
            break;
          case 'stderr':
            stderr += frame.data;
            break;
          case 'deny':
            denials.push({ kind: frame.kind, target: frame.target });
            break;
          case 'exit':
            stdin.end();
            settle(() => resolve({
              ok: frame.code === 0,
              enforcement,
              code: frame.code,
              stdout,
              stderr,
              denials,
            }));
            break;
          case 'error':
            settle(() => reject(new SandboxUnavailableError('runner', frame.message)));
            child.kill();
            break;
          default:
            break;
        }
      }
    });

    const helloFrame: HelloFrame = {
      v: PROTOCOL_VERSION,
      op: 'hello',
      scope: scope.id,
      ...(scope.parent !== undefined ? { parent: scope.parent } : {}),
      policy: policyName(scope.policy),
      isolation: scope.isolation,
    };
    stdin.write(encodeFrame(helloFrame));
  });
}

export async function sandboxProbe(scopeId?: string): Promise<ProbeResult[]> {
  void scopeId;
  return [];
}

export async function setSandboxPolicy(scopeId: string, policy: SandboxPolicy): Promise<void> {
  policies.set(scopeId, policy);
}

export function getSandboxPolicy(scopeId: string): SandboxPolicy | undefined {
  return policies.get(scopeId);
}

// ── Experiment batches (P2, docs/plans/sandbox-architecture.md §5.3.1) ──

export interface ExperimentVariantSpec {
  id: string;
  network?: NetworkPolicy;
}

export interface ExperimentBatch {
  id: string;
  /** <state>/experiments/<id>: batch root, writable by the batch scope. */
  root: string;
  /** Read-only in every variant. */
  baseline: string;
  variants: ExperimentVariantSpec[];
  seeds: number[];
  concurrency: number;
}

export interface ExperimentTask {
  variant: string;
  seed: number;
  attempt: number;
  scope: SandboxScope;
  dir: string;
  work: string;
  out: string;
}

export interface ExperimentResult {
  variant: string;
  seed: number;
  attempt: number;
  ok: boolean;
  code: number | null;
  stdout: string;
  stderr: string;
  error?: string;
}

export interface ExperimentRunOptions {
  /** Build the command for one (variant, seed, attempt). */
  makeRequest: (task: ExperimentTask) => SandboxRequest;
  /** Extra attempts after a failure; each attempt gets a fresh scope dir. */
  retries?: number;
  onStart?: (task: ExperimentTask) => void | Promise<void>;
  /** Remove `work/` after every attempt (default true); `out/` is kept. */
  cleanupWork?: boolean;
}

export interface ExperimentOutcome {
  batchId: string;
  results: ExperimentResult[];
  reproPath: string;
}

/**
 * Run the variants × seeds matrix with bounded concurrency. Every task gets
 * its own writable root (`<root>/<variant>/<seed>`), exclusive `work/`, and
 * the baseline mounted read-only. A failed task is retried in a fresh
 * `attempt-N` directory — a polluted `work/` is never reused.
 */
export async function runExperiment(
  batch: ExperimentBatch,
  options: ExperimentRunOptions,
): Promise<ExperimentOutcome> {
  if (!sandboxEnabled()) {
    throw new SandboxUnavailableError(
      'disabled',
      'TRHA_SANDBOX is off; refusing to run experiments',
    );
  }
  const retries = Math.max(0, options.retries ?? 0);
  mkdirSync(batch.baseline, { recursive: true });
  mkdirSync(batch.root, { recursive: true });

  const tasks: { variant: string; seed: number }[] = [];
  for (const v of batch.variants) for (const s of batch.seeds) tasks.push({ variant: v.id, seed: s });

  const results: ExperimentResult[] = [];
  let next = 0;
  const worker = async (): Promise<void> => {
    for (;;) {
      const index = next++;
      const item = tasks[index];
      if (!item) return;
      const { variant, seed } = item;
      let attempt = 0;
      let result: ExperimentResult | null = null;
      while (attempt <= retries) {
        const suffix = attempt === 0 ? '' : `attempt-${attempt}`;
        const dir = path.join(batch.root, variant, String(seed), suffix);
        const work = path.join(dir, 'work');
        const out = path.join(dir, 'out');
        mkdirSync(work, { recursive: true });
        mkdirSync(out, { recursive: true });
        const scope: SandboxScope = {
          id: `${batch.id}/${variant}/${seed}${suffix ? `/${suffix}` : ''}`,
          parent: batch.id,
          policy: { kind: 'workspace-write', root: dir, readonlyRoots: [batch.baseline] },
          isolation: 'process',
          scratch: work,
        };
        const task: ExperimentTask = { variant, seed, attempt, scope, dir, work, out };
        await options.onStart?.(task);
        let succeeded = false;
        try {
          const r = await sandboxedSpawn(scope, {
            ...options.makeRequest(task),
            experiment: `${batch.id}:${variant}:${seed}${suffix ? `:${suffix}` : ''}`,
          });
          result = {
            variant, seed, attempt,
            ok: r.ok, code: r.code, stdout: r.stdout, stderr: r.stderr,
          };
          succeeded = r.ok;
        } catch (e) {
          result = {
            variant, seed, attempt,
            ok: false, code: null, stdout: '', stderr: '',
            error: (e as Error).message,
          };
        }
        if (options.cleanupWork !== false) {
          rmSync(work, { recursive: true, force: true });
        }
        if (succeeded) break;
        attempt += 1;
      }
      if (result) results.push(result);
    }
  };
  await Promise.all(
    Array.from({ length: Math.max(1, batch.concurrency) }, () => worker()),
  );

  const reproPath = path.join(batch.root, 'repro.json');
  writeFileSync(reproPath, JSON.stringify({
    batch: batch.id,
    baseline: batch.baseline,
    variants: batch.variants.map(v => ({
      id: v.id,
      network: v.network ? 'on' : 'off',
    })),
    seeds: batch.seeds,
    concurrency: Math.max(1, batch.concurrency),
    toolchain: {},
  }, null, 2));

  return { batchId: batch.id, results, reproPath };
}
