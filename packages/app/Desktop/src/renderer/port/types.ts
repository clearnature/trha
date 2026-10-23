// Wire-level types for the trha scheduler REST + SSE surface (port layer).
// Shapes mirror the scheduler responses exactly (no invented fields).
// Pure types: no runtime code.

export interface PortSessionMessage {
  role: string;
  content: string;
  tool_calls?: { id: string; type: 'function'; function: { name: string; arguments: string } }[];
  tool_call_id?: string;
  [key: string]: unknown;
}

export interface PortToolSpec {
  name: string;
  description: string;
  parameters: { type: 'object'; properties: Record<string, unknown>; required: string[] };
}

export interface PortToolEvent {
  name: string;
  args: string[];
  status: 'running' | 'succeeded' | 'failed';
  durationMs?: number;
  error?: string;
}

export type PortEvent =
  | { type: 'message'; role: 'user' | 'assistant'; content: string }
  | { type: 'tool'; tool: PortToolEvent }
  | { type: 'plan'; status: 'awaiting_approval'; message: string }
  | { type: 'decision'; status: 'approved' | 'denied' }
  /** A streamed text increment (A3): the answer as it is produced. */
  | { type: 'delta'; text: string };

export interface PortModeConfig {
  name: string;
  description: string;
  tools: string[];
  persona: { enabled: boolean; template: string; maxBytes: number };
  compaction: { enabled: boolean; prunerEnabled: boolean; thresholdChars: number; headChars: number; tailChars: number };
  delegation: { enabled: boolean; forkEnabled: boolean; ralphEnabled: boolean; maxRounds: number };
  ptc: { enabled: boolean; language: string; description: string };
  hasPlan: boolean;
  hasTodo: boolean;
  hasWebSearch: boolean;
  hasShell: boolean;
  hasRunCode?: boolean; // optional: older/newer lines may omit
  maxTokens: number;
  contextSize: number;
}

export interface PortModel {
  name: string;
  description: string;
  contextSize: number;
}

export interface PortSession {
  id: string;
  mode: string;
  messages: PortSessionMessage[];
  pendingApproval: { message: string } | null;
  createdAt: string;
}

export interface StepResult {
  status?: 'completed';
  reply: string;
  messages: PortSessionMessage[];
  mode: string;
  /** Kernel causal-constraint verdict (D-1 / P3 wiring): pass | warn + t6/reach/edges/reason. */
  constraint?: Record<string, unknown>;
}

export interface PlanAwaiting {
  status: 'awaiting_approval';
  pending: { message: string };
  mode: string;
}

export type DecisionResult =
  | { status: 'approved'; reply: string; messages: PortSessionMessage[]; mode: string }
  | { status: 'denied'; mode: string };

export interface StudioVersion {
  current: string;
  pinned: string | null;
  versions: { version: string; current: boolean }[];
}
