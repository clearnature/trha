// Scheduler HTTP Server
// Exposes the scheduler as an HTTP API for the Desktop app
// Mode system ported from deepseek-harness standard/ptc/minimal/cordis presets

import express from 'express';
import cors from 'cors';
import { HaskellBridge } from '../Bridge/Haskell.js';
import type { BridgeToolSpec, ToolCallData } from '../Bridge/Haskell.js';
import { canonicalToolName, toolCatalog, toToolSpecs } from './toolCatalog.js';
import { decidePermission, setPermissionRules, compileRules, getPermissionRules } from '../Permission/permissionRules.js';
import {
  applyPermissionMode, toggleYolo, modeLabel, MODE_CYCLE,
  type PermissionMode,
} from '../Permission/modes.js';
import { EventEmitter } from '../Utils/EventEmitter.js';
import { SSE_EVENTS } from '../Core/EventRegistry.js';
import { Plugin, PluginManager } from '../Plugins/Plugin.js';
import { loadPluginsFrom } from '../Plugins/loader.js';
import { fileURLToPath } from 'node:url';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import { createServer as createHttpsServer } from 'node:https';
import { homedir } from 'node:os';
import { randomBytes } from 'node:crypto';
import { loadPin, loadSessionsSync, removeSessionFile, savePin, saveSession } from './stateStore.js';
import { govern, DEFAULT_GOVERNANCE, type GovernanceConfig } from './contextGovernor.js';
import { withRetry } from './retry.js';
import { envCap, envInt } from './env.js';
import { isSessionBusy, withSessionLock } from './sessionLock.js';
import { browserClose } from './browser.js';
import { mcpStatus } from './mcp.js';
import { fetchBalance } from './balance.js';
import { transcribeWav, AsrNotConfigured } from './transcribe.js';
import { lspStatus } from './lsp.js';
import { isExtraTool, runExtraTool, type ExtraHost, type Terminal } from './extraTools.js';
import {
  isStandardTool, runStandardTool,
  type AgentHooks, type Goal, type PendingQuestion, type Schedule, type TeamTask,
  type Todo, type JobRecord,
} from './standardTools.js';
import { startPluginWatcher } from '../Plugins/watcher.js';
import { resolveWorkspace } from './workspace.js';
import { readSandboxConfig, sandboxEnabled, sandboxStatus, setSandboxConfigRuntime, setSandboxEnabledRuntime, writeSandboxConfig, type SandboxConfigView } from './sandbox.js';
import { rateLimit } from './rateLimit.js';
import { DEFAULT_AGENT_PRESET, getAgentPreset, listAgentPresets } from './agentPresets.js';
// Side effect: registers plane + preset metadata for every tool (step 2 of the
// plugin migration). Handlers still live in the legacy chains.
import './toolDeclarations.js';
import { renderToolValue, resolveTool, toolNamesForPreset } from './toolRegistry.js';
import { agentDirs, loadAgentDefinitions } from './agentDefs.js';
import { resolveTls } from './tls.js';
import { resolveKernelToken } from '../Core/KernelToken.js';
import { mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';

export interface ServerConfig {
  port: number;
  /** Listen address; loopback only by default (host gate). */
  host?: string | undefined;
  token: string;
  haskellHost: string;
  haskellPort: number;
  /** Plugins registered at startup (Phase 3 plugin architecture). */
  plugins?: Plugin[] | undefined;
  /** Directory of plugin modules (*.js/*.mjs, default-export Plugin) loaded at startup. */
  pluginsDir?: string | undefined;
  /** Hot-reload the plugins directory (default true). */
  watchPlugins?: boolean | undefined;
  /** Directory for server-side session persistence (absent = memory only). */
  stateDir?: string | undefined;
  /** Directory of static /studio pages (default: scheduler/studio-public). */
  studioDir?: string | undefined;
  /** Unix domain socket for host-local IPC (no TCP network surface). */
  socketPath?: string | undefined;
}

export const defaultServerConfig: ServerConfig = {
  port: 28433,
  host: '127.0.0.1',
  token: process.env.TRHA_TOKEN || 'dev-token',
  haskellHost: 'localhost',
  haskellPort: 19433,
};

// ── Tool definitions ──────────────────────────────────────────────────────

interface ToolDef {
  name: string;
  description: string;
  enabled: boolean;
  schema: Record<string, string>;
}

/**
 * The tool list the *HTTP* surface advertises (`/api/tools`, `/api/modes`),
 * derived from `toolCatalog` — the same list the model is offered and the
 * executor dispatches — so "advertised" and "executable" cannot drift again.
 *
 * The hand-written `ALL_TOOLS` array this route used to serve is gone: it named
 * 44 tools with no executor at all and disagreed with the executor on 10 more
 * (`edit` wanted `file_path`, `web_search` wanted `queries`, `run_code` had no
 * `language`, `job_output`/`job_kill` wanted `job_id`, …), so a client that
 * followed /api/tools got either `ERROR: unknown tool` or a missing-argument
 * error on a perfectly valid call.
 */
const catalogToolDefs = (): ToolDef[] => toolCatalog.map(def => {
  const required = new Set(def.parameters.required);
  const schema: Record<string, string> = {};
  for (const [key, raw] of Object.entries(def.parameters.properties)) {
    const prop = raw as { type?: string; items?: { type?: string }; enum?: unknown[] };
    const type = prop.type === 'array'
      ? `${prop.items?.type ?? 'string'}[]`
      : (prop.enum ? 'string' : prop.type ?? 'string');
    schema[key] = required.has(key) ? type : `${type}?`;
  }
  return { name: def.name, description: def.description, enabled: true, schema } satisfies ToolDef;
});

// ── Tool lifecycle event (Phase 2 S2) ─────────────────────────────────
// Pushed to /api/events/:sessionId as `tool:update`; mirrors CLI ToolEvent.

interface ToolEvent {
  name: string;
  args?: string[];
  status: 'running' | 'succeeded' | 'failed';
  error?: string;
  durationMs?: number;
  /** Tail preview of the tool output (only on `succeeded`), for the TUI's
   * expandable tool card.  Optional so older shells ignore it. */
  output?: string;
}

/** Tail-capped output preview for tool cards: last 12 lines, at most 2 KiB. */
const OUTPUT_PREVIEW_LINES = 12;
const OUTPUT_PREVIEW_BYTES = 2048;
const outputPreview = (output: string): string => {
  const tail = output.split('\n').slice(-OUTPUT_PREVIEW_LINES).join('\n');
  return tail.length > OUTPUT_PREVIEW_BYTES ? '…' + tail.slice(-OUTPUT_PREVIEW_BYTES) : tail;
};

/**
 * Unified diff for the edit tool's result: the TUI renders it as a patch card
 * (MiMo parity) instead of just "1 replacement".  Line numbers come from the
 * pre-edit content; `replace_all` shows the first occurrence.
 */
// ── Session shape ───────────────────────────────────────────────────────
// One server-side session.  `pendingApproval` holds a plan request waiting
// for a host decision (Phase 2 S1 approval gate).

interface SessionMessage {
  role: string;
  content: string;
  tool_calls?: unknown[] | undefined;
  tool_call_id?: string | undefined;
  [key: string]: unknown;
}

/** The per-turn provider/model choice forwarded to the kernel. */
/** Role-specific effort overrides: TRHA_ROLE_EFFORTS="planner=high,coder=low". */
export const roleEffort = (role?: string): string | undefined => {
  if (!role) return undefined;
  const hit = (process.env.TRHA_ROLE_EFFORTS ?? '')
    .split(',')
    .map(s => s.split('=').map(x => x.trim()))
    .find(([r]) => !!r && r.toLowerCase() === role.toLowerCase());
  const level = hit?.[1];
  return level && level.toLowerCase() !== 'auto' ? level : undefined;
};

/** Per-profile subagent overrides: TRHA_SUBAGENT_EFFORTS="reviewer=max,task=high". */
export const subagentEfforts = (profile?: string): string | undefined => {
  if (!profile) return undefined;
  const hit = (process.env.TRHA_SUBAGENT_EFFORTS ?? '')
    .split(',')
    .map(s => s.split('=').map(x => x.trim()))
    .find(([r]) => !!r && r.toLowerCase() === profile.toLowerCase());
  const level = hit?.[1];
  return level && level.toLowerCase() !== 'auto' ? level : undefined;
};

/** Sub-agent reasoning depth override (Reasonix's agent.subagent_effort). */
export const subagentEffort = (): string | undefined => {
  const e = (process.env.TRHA_SUBAGENT_EFFORT ?? '').trim();
  return e && e.toLowerCase() !== 'auto' ? e : undefined;
};

interface TurnTarget {
  provider?: string | undefined;
  model?: string | undefined;
  genParams?: { temperature?: number | undefined; topP?: number | undefined; maxTokens?: number | undefined; effort?: string | undefined } | undefined;
  /** Language the model should reason in (absent / "auto" = default). */
  reasoningLanguage?: string | undefined;
  /** Agent-definition allow-list: when set, only these tools are offered. */
  toolsAllow?: string[] | undefined;
  /** Extra system instructions from an agent definition. */
  extraInstructions?: string | undefined;
}

interface SchedulerSession {
  id: string;
  mode: string;
  messages: SessionMessage[];
  // A parked approval keeps the turn's target so the replay after "approve"
  // uses the same provider/model the user had selected (otherwise it would
  // silently fall back to the kernel's in-use provider).
  pendingApproval: ({ message: string } & TurnTarget) | null;
  /** When the gate was parked, so /ask-timeout can expire it. */
  pendingApprovalAt?: string | null;
  /** Approval wait for this session (ms); overrides TRHA_APPROVAL_TIMEOUT_MS. */
  askTimeoutMs?: number;
  /** The last turn, so /retry can replay it exactly. */
  lastRequest?: ({ message: string } & TurnTarget) | null;
  /** Messages queued with /queue; drained after the current turn. */
  queued?: { message: string; target?: TurnTarget }[];
  /** Instructions injected with /steer; consumed at the next model call. */
  steer?: string[];
  createdAt: Date;
  /** Provider-reported prompt tokens of the previous request (ground truth). */
  lastPromptTokens?: number;
  cacheHitTokens?: number;
  cacheMissTokens?: number;
  completionTokens?: number;
  /** How many times context maintenance rewrote the prefix (each one is a cache miss). */
  prefixResets?: number;
  lastMaintenance?: { trigger: string; savedTokens: number } | null;
  /** Standard-tool state (ported from dsh's standard preset). */
  todos?: Todo[];
  goal?: Goal | null;
  schedules?: Schedule[];
  pendingQuestion?: PendingQuestion | null;
  /** Subagent linkage: a child session points at the one that spawned it. */
  parentId?: string;
  depth?: number;
  abortRequested?: boolean;
  /** Team tasks are shared on the root session. */
  teamTasks?: TeamTask[];
  /** Tool working directory for this session (inside the workspace). */
  cwd?: string;
  /**
   * The session's workspace *root*: set by `/workspace` (or at creation) and
   * never moved by the `cd` tool.  `cwd` may be any descendant of this; the
   * tools clamp to it, so an agent cannot walk out of the project it was given.
   */
  workspaceRoot?: string;
  /** Cards shown to the user; never part of the model's history. */
  presentations?: Array<{ card: string; at: string }>;
  /** User-facing title and tags (rename/tag; absent until set). */
  title?: string;
  tags?: string[];
  /** Session permission posture (Shift+Tab cycle / Ctrl+Y YOLO). */
  permissionMode?: PermissionMode;
  planMode?: boolean;
  yoloRestore?: PermissionMode | null;
}

// ── Context governance (window / thresholds) ──────────────────────────────
// The override exists so tests can force pressure without a 1M-token session.
function governanceConfig(): GovernanceConfig {
  const window = Number(process.env.TRHA_CONTEXT_WINDOW ?? '');
  return {
    ...DEFAULT_GOVERNANCE,
    ...(Number.isFinite(window) && window > 0 ? { window } : {}),
  };
}

// ── Mode definitions (ported from deepseek-harness presets) ───────────────

interface ModeConfig {
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
  maxTokens: number;
  contextSize: number;
}


/** Tool discipline that applies to every mode with a plan/todo surface. */
const TOOL_DISCIPLINE = [
  'Tool discipline:',
  '- `todo_write` replaces the whole list. Write it once when the plan is set, and at most once',
  '  more when the batch of work is finished. Do not rewrite it after every individual action;',
  '  if nothing in the list changed, do not call it at all.',
  '- Batch independent tool calls into one turn instead of one call per turn.',
].join('\n');

/** Render the mode persona as the system message (the config existed but was never sent). */
function systemMessageFor(mode: ModeConfig, model: string, cwd: string): string | null {
  if (!mode.persona.enabled) return null;
  const body = mode.persona.template
    .replace(/\{\{\s*model\s*\}\}/g, model)
    .replace(/\{\{\s*cwd\s*\}\}/g, cwd);
  const text = `${body}\n\n${TOOL_DISCIPLINE}`;
  return text.slice(0, mode.persona.maxBytes || text.length);
}

/** Human-readable names for the BCP 47 tags the shell sends.  A bare tag is
 *  understandable, but naming the language is what actually steers a model. */
const REASONING_LANGUAGE_NAMES: Record<string, string> = {
  'zh-hans': 'Simplified Chinese (简体中文)',
  'zh-hant': 'Traditional Chinese (繁體中文)',
  en: 'English',
  fr: 'French',
  es: 'Spanish',
  ru: 'Russian',
  th: 'Thai',
  my: 'Burmese',
  bo: 'Tibetan',
  ii: 'Nuosu Yi',
};

/** A reasoning-language tag from the wire: trimmed, short, tag-shaped. */
function reasoningLanguageTag(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const t = v.trim();
  return t && t.length <= 32 && /^[A-Za-z0-9-]+$/.test(t) ? t : undefined;
}

function reasoningLanguageName(tag: string): string {
  return REASONING_LANGUAGE_NAMES[tag.toLowerCase()] ?? tag;
}

/** Upper bound for the rules text appended to the system prompt. */
const RULES_MAX_BYTES = 65536;

/**
 * Rules dropped in `~/.trha/rules/*.md`, appended to the system prompt.
 *
 * Global rules are the user-level counterpart of a project's `AGENTS.md`
 * (reference CLIs keep them in `~/.claude/rules`, `~/.codex/rules`, …).
 * Read per request so an edit takes effect on the next turn; unreadable
 * files and a missing directory are skipped silently.
 */
async function loadRuleFiles(): Promise<string> {
  const dir = process.env.TRHA_RULES_DIR?.trim() || path.join(homedir(), '.trha', 'rules');
  let names: string[];
  try {
    names = (await readdir(dir)).filter(n => n.endsWith('.md')).sort();
  } catch {
    return '';
  }
  const chunks: string[] = [];
  for (const name of names) {
    try {
      const body = (await readFile(path.join(dir, name), 'utf8')).trim();
      if (body) chunks.push(`# ${path.basename(name, '.md')}\n\n${body}`);
    } catch {
      /* an unreadable rule must not break the turn */
    }
  }
  if (!chunks.length) return '';
  return `\n\nGlobal rules (~/.trha/rules):\n\n${chunks.join('\n\n')}`.slice(0, RULES_MAX_BYTES);
}

/** Session messages as the model should see them: a system message first, then the rest. */
async function withSystemPrompt(
  mode: ModeConfig, model: string, cwd: string,
  messages: Array<{ role: string; content: string }>,
  reasoningLanguage?: string,
  extraInstructions?: string,
): Promise<Array<Record<string, unknown>>> {
  const base = systemMessageFor(mode, model, cwd);
  const code = (reasoningLanguage ?? '').trim();
  const langSuffix = code && code.toLowerCase() !== 'auto'
    ? `\n\nReason about the problem in ${reasoningLanguageName(code)}; answer in the user's language.`
    : '';
  const agentSuffix = extraInstructions?.trim()
    ? `\n\nAgent instructions:\n\n${extraInstructions.trim()}`
    : '';
  const rules = await loadRuleFiles();
  const system = base
    ? base + agentSuffix + langSuffix + rules
    : ((agentSuffix + langSuffix + rules).trim() || null);
  // Computed per request instead of stored: a stored system message would be
  // rewritten by maintenance and would pollute the transcript the shell shows.
  return system
    ? [{ role: 'system', content: system }, ...messages]
    : [...messages];
}

// Built-in workflow templates (/workflow).  Each one is a prompt the current
// session runs as a normal turn, so it inherits mode/model/tools.
export const WORKFLOW_TEMPLATES: { name: string; description: string; prompt: string }[] = [
  {
    name: 'init',
    description: 'Create an AGENTS.md contributor guide',
    prompt:
      'Analyse this repository and write an AGENTS.md contributor guide: layout, build/test commands, ' +
      'conventions, and the traps a new contributor would hit.',
  },
  {
    name: 'review',
    description: 'Review the working-tree changes',
    prompt:
      'Review the current working-tree changes for correctness, regressions and missing tests. ' +
      'Report findings as file:line with a one-line fix suggestion each.',
  },
  {
    name: 'dream',
    description: 'Brainstorm improvements',
    prompt:
      'Brainstorm concrete improvements for this project: dead code, unclear abstractions, missing tests, ' +
      'and one larger idea. Rank by value and effort.',
  },
  {
    name: 'deep-research',
    description: 'Research a question and write a cited report',
    prompt: 'Research the following question, cross-check sources, and write a concise cited report:\n',
  },
];

const MODES: Record<string, ModeConfig> & { standard: ModeConfig } = {
  standard: {
    name: 'standard',
    description: 'Full coding agent with all tools and capabilities',
    tools: catalogToolDefs().map(t => t.name).filter(n => toolNamesForPreset('standard').has(n)),
    persona: {
      enabled: true,
      template: 'You are a coding agent powered by the {{model}} model.\nYour working directory is {{cwd}}.',
      maxBytes: 65536,
    },
    compaction: { enabled: true, prunerEnabled: true, thresholdChars: 8192, headChars: 4096, tailChars: 1024 },
    delegation: { enabled: true, forkEnabled: true, ralphEnabled: true, maxRounds: 64 },
    ptc: { enabled: false, language: '', description: '' },
    hasPlan: true, hasTodo: true, hasWebSearch: true, hasShell: true,
    maxTokens: 8192, contextSize: 131072,
  },
  ptc: {
    name: 'ptc',
    description: 'Program-the-code: model writes a program, one call multi-tool',
    tools: catalogToolDefs().map(t => t.name).filter(n => toolNamesForPreset('ptc').has(n)),
    persona: {
      enabled: true,
      template: 'You are a coding agent powered by the {{model}} model.\nYour working directory is {{cwd}}.\n\n`run_code` is the only tool you can call directly — a tool call naming any other tool fails.\nReach every tool the SDK declares below from inside the program.',
      maxBytes: 65536,
    },
    compaction: { enabled: true, prunerEnabled: true, thresholdChars: 8192, headChars: 4096, tailChars: 1024 },
    delegation: { enabled: true, forkEnabled: true, ralphEnabled: true, maxRounds: 64 },
    ptc: {
      enabled: true,
      language: 'typescript',
      description: 'Execute a TypeScript program against the available tools. Takes `code` (body of an async function) and `description`. Call tools as `await tools.name(args)`. Only what you print or return is output.',
    },
    hasPlan: false, hasTodo: false, hasWebSearch: true, hasShell: true,
    maxTokens: 16384, contextSize: 131072,
  },
  minimal: {
    name: 'minimal',
    description: 'Lightweight: basic tools only, no compaction or plan',
    tools: catalogToolDefs().map(t => t.name).filter(n => toolNamesForPreset('minimal').has(n)),
    persona: { enabled: false, template: '', maxBytes: 0 },
    compaction: { enabled: false, prunerEnabled: false, thresholdChars: 0, headChars: 0, tailChars: 0 },
    delegation: { enabled: false, forkEnabled: false, ralphEnabled: false, maxRounds: 0 },
    ptc: { enabled: false, language: '', description: '' },
    hasPlan: false, hasTodo: false, hasWebSearch: false, hasShell: true,
    maxTokens: 4096, contextSize: 65536,
  },
  cordis: {
    name: 'cordis',
    description: 'Base layer: user composes their own tool set',
    tools: [],
    persona: { enabled: false, template: '', maxBytes: 0 },
    compaction: { enabled: true, prunerEnabled: true, thresholdChars: 8192, headChars: 4096, tailChars: 1024 },
    delegation: { enabled: true, forkEnabled: true, ralphEnabled: true, maxRounds: 64 },
    ptc: { enabled: false, language: '', description: '' },
    hasPlan: false, hasTodo: false, hasWebSearch: false, hasShell: true,
    maxTokens: 4096, contextSize: 65536,
  },
};

// ── Server factory ────────────────────────────────────────────────────────

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const SESSION_COOKIE = 'trha_session';

/** Read one cookie by name from a Cookie header (no cookie-parser dep). */
function cookieValue(header: string | undefined, name: string): string | undefined {
  if (!header) return undefined;
  for (const part of header.split(';')) {
    const [k, ...rest] = part.trim().split('=');
    if (k === name) return rest.join('=');
  }
  return undefined;
}

/**
 * The Web UI build (packages/app/Web/dist), when present. `/studio` serves it
 * in preference to the legacy Desktop export.
 */
function webUiBuildDir(): string | null {
  const candidate = path.join(__dirname, '..', '..', '..', 'app', 'Web', 'dist');
  return existsSync(path.join(candidate, 'index.html')) ? candidate : null;
}

/** Best-effort scheduler version from package.json (dev fallback). */
export function schedulerVersion(): string {
  try {
    const pkg = JSON.parse(readFileSync(
      path.join(__dirname, '..', '..', 'package.json'), 'utf8')) as { version?: string };
    return pkg.version ?? '0.0.0-dev';
  } catch {
    return '0.0.0-dev';
  }
}

export function createServer(config: ServerConfig = defaultServerConfig) {
  const app = express();
  const events = new EventEmitter();
  const sessionSecret = randomBytes(24).toString('hex');
  const bridge = new HaskellBridge({ host: config.haskellHost, port: config.haskellPort, tokenProvider: resolveKernelToken });

  // ── Plugin runtime (Phase 3) ────────────────────────────────────────────
  // Hooks fire asynchronously; plugin failures are logged, never fatal.
  const plugins = new PluginManager(events);
  plugins.registerService('events', events, ['events:listen', 'events:emit']);
  plugins.registerService('bridge', bridge, ['model:query', 'sessions:list']);
  plugins.registerService('pluginManager', plugins, ['plugins:register']);
  const emitSafe = (p: Promise<void>) => {
    p.catch(e => console.error('plugin hook error:', e));
  };
  for (const plugin of config.plugins ?? []) {
    void plugins.register(plugin).catch(e => console.error(`plugin ${plugin.name} init failed:`, e));
  }
  if (config.pluginsDir) {
    void loadPluginsFrom(config.pluginsDir).then(loaded => {
      for (const p of loaded) {
        void plugins.register(p).catch(e => console.error(`plugin ${p.name} init failed:`, e));
      }
    }).catch(e => console.error(`pluginsDir scan failed (${config.pluginsDir}):`, e));

    if (config.watchPlugins !== false) {
      // hot reload: new / changed / removed plugin files reconcile automatically
      startPluginWatcher(config.pluginsDir, plugins);
    }
  }

  // CORS: this listener's own origins only.  A wildcard `cors()` makes every
  // page the user happens to visit a potential caller of the API — with the
  // Bearer token being the only thing standing in the way.
  app.use(cors({
    origin: (origin, cb) => {
      if (!origin) return cb(null, true);   // non-browser callers (CLI/curl)
      const port = config.port;
      const allowed = [
        `https://localhost:${port}`, `http://localhost:${port}`,
        `https://127.0.0.1:${port}`, `http://127.0.0.1:${port}`,
      ];
      cb(null, allowed.includes(origin));
    },
    credentials: true,
  }));
  app.use(express.json());

  // Authentication: Bearer token by default; the /studio pages are served
  // from this same loopback listener, so same-origin requests (browser sends
  // an Origin header equal to this listener) bypass the token -- mirroring
  // the Reasonix loopback gate.  Cross-origin browsers are always refused;
  // token-less non-browser callers keep working through the Bearer check.
  app.use((req, res, next) => {
    const loopbackOnly = (config.host ?? '127.0.0.1') === '127.0.0.1';
    // `/health` is always open (the CLI probes it before it has a token).
    //
    // `/v1/*` and `/studio` are "same-host only": they exist for local tools
    // and the bundled UI on this loopback listener.  Exempting them
    // unconditionally is how a harness leaks an unauthenticated LLM endpoint
    // the moment someone sets `TRHA_HOST=0.0.0.0` — the incident that pushed
    // comparable tools to SSH tunnels instead of public ports.
    if (req.path === '/health') return next();
    if (loopbackOnly && (req.path.startsWith('/v1/') || req.path.startsWith('/studio'))) {
      return next();
    }
    const origin = req.headers.origin;
    const isRead = req.method === 'GET' || req.method === 'HEAD' || req.method === 'OPTIONS';
    const sessionOk = cookieValue(req.headers.cookie, SESSION_COOKIE) === sessionSecret;
    const authOk = req.headers.authorization === `Bearer ${config.token}`
      || req.query.token === config.token;

    if (!origin) {
      // Non-browser (CLI/curl): loopback-only origin-less READS are allowed
      // (Reasonix model); every write needs the Bearer token.
      if (isRead && loopbackOnly) return next();
      if (authOk) return next();
      return res.status(401).json({ error: 'Unauthorized', code: 'unauthorized' });
    }
    // Browser: only this listener's own origin may proceed at all.
    const self = `http://${req.headers.host}`;
    if (origin !== self) {
      return res.status(403).json({ error: 'cross-origin request denied', code: 'origin' });
    }
    // Same-origin page: the HttpOnly session cookie is the credential (a
    // local non-page process cannot read it).  Cold-navigation reads
    // (before the cookie exists) are allowed on loopback only.
    if (sessionOk) return next();
    if (isRead && loopbackOnly) return next();
    return res.status(401).json({ error: 'session required', code: 'session' });
  });

  // ── Health ────────────────────────────────────────────────────────────

  // Root is not an API route: send browsers to the studio pages. The API
  // lives under /api/*, so "Cannot GET /" was what users saw before.
  app.get('/', (_req, res) => {
    res.redirect(302, '/studio/');
  });

  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', version: '0.1.0', modes: Object.keys(MODES) });
  });

  // ── /studio pages + version surface (loopback host; one routing rule:
  // /studio* -> static page assets, everything else stays on the API) ──
  //
  // Preference: explicit config / TRHA_STUDIO_DIR → the Web UI build
  // (packages/app/Web/dist) → the legacy Desktop export (studio-public).
  const studioDir = config.studioDir
    ?? process.env.TRHA_STUDIO_DIR?.trim()
    ?? webUiBuildDir()
    ?? path.join(__dirname, '..', '..', 'studio-public');
  app.use('/studio', (req, res, next) => {
    // Refresh the credential when it is missing *or stale*: a browser keeps
    // the cookie from a previous scheduler process, whose secret no longer
    // matches — without this every write from the reloaded page 401s with
    // "session required" until the user clears cookies by hand.
    const current = cookieValue(req.headers.cookie, SESSION_COOKIE);
    if ((req.method === 'GET' || req.method === 'HEAD') && current !== sessionSecret) {
      res.setHeader('Set-Cookie',
        `${SESSION_COOKIE}=${sessionSecret}; HttpOnly; SameSite=Strict; Path=/`);
    }
    next();
  });
  app.use('/studio', express.static(studioDir));

  const pinnedVersion = new Map<string, string | null>();
  app.get('/studio/versions', async (_req, res) => {
    const current = schedulerVersion();
    let pinned = pinnedVersion.get('current') ?? null;
    if (config.stateDir && pinned === null) {
      pinned = await loadPin(config.stateDir).catch(() => null);
    }
    res.json({
      current,
      pinned,
      versions: [{ version: current, current: true }],
    });
  });
  app.post('/studio/pin', async (req, res) => {
    const version = (req.body ?? {}).version;
    if (typeof version !== 'string' || version.trim() === '') {
      return res.status(400).json({ error: 'version required' });
    }
    const target = version.trim();
    pinnedVersion.set('current', target);
    if (config.stateDir) {
      await savePin(config.stateDir, target).catch(e =>
        console.error('persist pin:', e));
    }
    res.json({ ok: true, pinned: target });
  });

  app.get('/api/plugins', (_req, res) => {
    res.json(plugins.listPlugins().map(p => ({
      name: p.name,
      version: p.version,
      description: p.description,
    })));
  });

  // Declarative (hook-less) plugins can be registered/unregistered at
  // runtime.  Plugins carrying JS hooks must still be provided at startup
  // via ServerConfig.plugins -- functions cannot cross the HTTP boundary.
  app.post('/api/plugins', async (req, res) => {
    const { name, version, description } = req.body ?? {};
    if (typeof name !== 'string' || !name.trim()
        || typeof version !== 'string' || typeof description !== 'string') {
      return res.status(400).json({ error: 'name/version/description required' });
    }
    try {
      await plugins.register({ name: name.trim(), version, description });
      return res.status(201).json({ ok: true, name: name.trim() });
    } catch (e) {
      return res.status(409).json({ error: (e as Error).message });
    }
  });

  // ── Workspace files (web sidebar "Files") ─────────────────────────────
  //
  // Top-level listing of the session workspace: cheap, bounded, and free of
  // build/VCS noise. `sessionId` picks that session's cwd; otherwise the
  // scheduler workspace is used.
  app.get('/api/workspace/files', async (req, res) => {
    const sid = typeof req.query.sessionId === 'string' ? req.query.sessionId : '';
    const rawLimit = Number(req.query.limit);
    const limit = Math.max(1, Math.min(100, Number.isFinite(rawLimit) && rawLimit > 0 ? Math.floor(rawLimit) : 20));
    const root = (sid ? sessions.get(sid)?.cwd : undefined) ?? WORKSPACE;
    const IGNORE = new Set([
      '.git', 'node_modules', 'dist-newstyle', '.stack-work',
      '__pycache__', '.venv', 'target',
    ]);
    try {
      const entries = await readdir(root, { withFileTypes: true });
      const files = entries
        .filter(e => !IGNORE.has(e.name))
        .sort((a, b) => a.name.localeCompare(b.name))
        .slice(0, limit)
        .map(e => ({ path: e.name + (e.isDirectory() ? '/' : ''), dir: e.isDirectory() }));
      res.json({ root, files });
    } catch (e) {
      res.status(500).json({ error: (e as Error).message });
    }
  });

  // ── Workspace file content (web right panel preview) ──────────────────
  //
  // Reads one file inside the session workspace. Directory traversal is
  // rejected, and the payload is capped so a preview can never pull a
  // build artefact into the browser.
  app.get('/api/workspace/file', async (req, res) => {
    const raw = typeof req.query.path === 'string' ? req.query.path : '';
    if (!raw.trim()) return res.status(400).json({ error: 'path is required' });
    const sid = typeof req.query.sessionId === 'string' ? req.query.sessionId : '';
    const root = (sid ? sessions.get(sid)?.cwd : undefined) ?? WORKSPACE;
    const target = path.resolve(root, raw);
    if (target !== root && !target.startsWith(root + path.sep)) {
      return res.status(403).json({ error: 'path escapes the workspace' });
    }
    try {
      const info = await stat(target);
      if (!info.isFile()) return res.status(400).json({ error: 'not a file' });
      if (info.size > 256 * 1024) return res.status(413).json({ error: 'file too large' });
      const text = await readFile(target, 'utf8');
      res.json({ path: raw, size: info.size, text });
    } catch {
      res.status(404).json({ error: 'not found' });
    }
  });

  app.get('/api/services', (_req, res) => {
    res.json(plugins.describeServices());
  });

  app.delete('/api/plugins/:name', async (req, res) => {
    try {
      await plugins.unregister(req.params.name);
      return res.json({ ok: true, name: req.params.name });
    } catch (e) {
      return res.status(404).json({ error: (e as Error).message });
    }
  });

  // ── Modes ─────────────────────────────────────────────────────────────

  app.get('/api/modes', (_req, res) => {
    res.json(MODES);
  });

  app.get('/api/modes/:name', (req, res) => {
    const mode = MODES[req.params.name];
    if (!mode) return res.status(404).json({ error: 'Mode not found' });
    res.json(mode);
  });

  // ── Tools (filtered by mode) ──────────────────────────────────────────

  app.get('/api/tools', (req, res) => {
    const modeName = req.query.mode as string;
    if (modeName && MODES[modeName]) {
      const modeTools = MODES[modeName].tools;
      res.json(catalogToolDefs().filter(t => modeTools.includes(t.name)));
    } else {
      res.json(catalogToolDefs());
    }
  });

  // ── Models ────────────────────────────────────────────────────────────

  // What api.deepseek.com actually serves (verified 2026-10); the window is
  // what context governance sizes its thresholds against.
  // Working limits, not the model ceiling: 500k context / 128k output. Raising
  // them again is a config change, not a code change.
  const models = [
    { name: 'deepseek-flash', description: 'DeepSeek-V4.1-Flash', contextSize: 524288, maxOutputTokens: 131072 },
    { name: 'deepseek-v4-pro', description: 'DeepSeek-V4-Pro', contextSize: 524288, maxOutputTokens: 131072 },
  ];

  app.get('/api/models', (_req, res) => {
    res.json(models);
  });

  // ── Provider registry (P4): forward to the kernel's /providers* ───────
  //
  // The kernel owns the registry (config, keys, probing); the scheduler is
  // the only door the UI uses, so it forwards -- status and coded refusals
  // included -- instead of duplicating any of it.

  const kernelBase = () => `http://${config.haskellHost}:${config.haskellPort}`;

  /** The kernel gate wants a Bearer token on every route; resolve it per
   *  request because the kernel may mint `~/.trha/kernel-token` after we boot. */
  const kernelAuthHeaders = (): Record<string, string> => {
    const token = resolveKernelToken();
    return token ? { Authorization: `Bearer ${token}` } : {};
  };

  async function forwardToKernel(
    res: import('express').Response,
    method: 'GET' | 'POST',
    path: string,
    body?: unknown,
  ): Promise<void> {
    try {
      const doFetch = (): Promise<globalThis.Response> =>
        fetch(`${kernelBase()}${path}`, {
          method,
          headers: { 'Content-Type': 'application/json', ...kernelAuthHeaders() },
          ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        });
      let r = await doFetch();
      // A kernel restart rotates the shared token; retry once with the new one.
      if (r.status === 401) r = await doFetch();
      const text = await r.text();
      res.status(r.status).type('application/json').send(text || '{}');
    } catch (e) {
      res.status(502).json({ code: 'provider.kernel_unreachable', error: String(e) });
    }
  }

  /** One text stream from the bridge: real increments when the kernel can
   * stream, the whole reply as a single increment when it cannot (A3). */
  async function streamReply(
    messages: [string, string][],
    onText: (text: string) => void,
  ): Promise<void> {
    try {
      await bridge.queryModelStream({ messages }, onText);
    } catch {
      const r = await bridge.queryModel({ messages });
      if (r.reply) onText(r.reply);
    }
  }

  // ── Permission rules（内核权限规则引擎）────────────
  // ── 用量统计（UsageStatsPanel；scheduler 聚合 sessions）────────
  // Usage accounting comes from the provider's own numbers, never from a
  // character estimate: cached prompt tokens bill at a different rate, so a
  // fake average would hide the one lever that moves the bill.
  app.get('/api/usage-stats', (_req, res) => {
    type Agg = {
      requests: number; messages: number; prompt: number; completion: number;
      cacheHit: number; cacheMiss: number; resets: number;
    };
    const byModel = new Map<string, Agg>();
    for (const s of sessions.values()) {
      const key = s.mode || 'default';
      const cur = byModel.get(key) ?? {
        requests: 0, messages: 0, prompt: 0, completion: 0,
        cacheHit: 0, cacheMiss: 0, resets: 0,
      };
      cur.messages += s.messages.length;
      cur.requests += s.messages.filter(m => m.role === 'assistant').length;
      cur.prompt += s.lastPromptTokens ?? 0;
      cur.completion += s.completionTokens ?? 0;
      cur.cacheHit += s.cacheHitTokens ?? 0;
      cur.cacheMiss += s.cacheMissTokens ?? 0;
      cur.resets += s.prefixResets ?? 0;
      byModel.set(key, cur);
    }
    const price = {
      input: Number(process.env.TRHA_PRICE_INPUT ?? ''),
      cached: Number(process.env.TRHA_PRICE_CACHED ?? ''),
      output: Number(process.env.TRHA_PRICE_OUTPUT ?? ''),
    };
    const priced = Number.isFinite(price.input) && price.input > 0
                && Number.isFinite(price.cached) && price.cached > 0
                && Number.isFinite(price.output) && price.output > 0;
    const rows = Array.from(byModel.entries()).map(([model, v]) => {
      const denom = v.cacheHit + v.cacheMiss;
      // Without prices configured, say so instead of inventing a number.
      const cost = priced
        ? ((v.cacheMiss * price.input + v.cacheHit * price.cached + v.completion * price.output) / 1e6)
            .toFixed(4)
        : '—';
      return {
        model,
        requests: v.requests,
        messages: v.messages,
        tokens: denom,
        promptTokens: denom,
        completionTokens: v.completion,
        cacheHitTokens: v.cacheHit,
        cacheMissTokens: v.cacheMiss,
        cacheHitRatio: denom > 0 ? Number((v.cacheHit / denom).toFixed(4)) : 0,
        contextResets: v.resets,
        cost,
      };
    });
    res.json({ range: 'all', rows });
  });

  // ── Hooks 配置（HooksPanel 保存；落盘 ~/.trha/hooks.json）────────
  const HOOKS_FILE = process.env.TRHA_HOOKS_FILE
    ?? (process.env.HOME ? `${process.env.HOME}/.trha/hooks.json` : '/tmp/trha-hooks.json');
  let hooksConfig: string = '{\n  "hooks": {}\n}';
  void (async () => {
    try { hooksConfig = await readFile(HOOKS_FILE, 'utf8'); } catch { /* 首次无文件 */ }
  })();
  app.get('/api/hooks', (_req, res) => {
    res.json({ config: hooksConfig, path: HOOKS_FILE });
  });
  app.put('/api/hooks', async (req, res) => {
    try {
      const raw = req.body?.config ?? req.body;
      if (typeof raw !== 'string') return res.status(400).json({ error: 'config must be a JSON string' });
      JSON.parse(raw);   // 校验 JSON 合法性
      hooksConfig = raw;
      await mkdir(path.dirname(HOOKS_FILE), { recursive: true });
      await writeFile(HOOKS_FILE, raw, 'utf8');
      res.json({ config: hooksConfig, path: HOOKS_FILE });
    } catch (e) {
      res.status(400).json({ error: (e as Error).message });
    }
  });

  // ── 记忆（MemoryPanel；背景/归档/指令文件，分类筛选）────────
  const MEMORY_FILE = process.env.TRHA_MEMORY_FILE
    ?? (process.env.HOME ? `${process.env.HOME}/.trha/memory.json` : '/tmp/trha-memory.json');
  interface MemoryItem { id: string; title: string; slug: string; category: 'feedback' | 'project' | 'preferences'; excerpt: string; }
  let memoryItems: MemoryItem[] = [];
  void (async () => {
    try { memoryItems = JSON.parse(await readFile(MEMORY_FILE, 'utf8')); } catch { /* 首次无 */ }
  })();
  app.get('/api/memory', (_req, res) => {
    const archived = memoryItems.filter((m: MemoryItem) => (m as { archived?: boolean }).archived).length;
    res.json({ items: memoryItems, stats: {
      background: memoryItems.length, archived, instructionFiles: 0,
    } });
  });
  app.put('/api/memory', async (req, res) => {
    try {
      const items = Array.isArray(req.body?.items) ? req.body.items : [];
      if (!items.every((m: unknown) => m && typeof (m as MemoryItem).title === 'string'))
        return res.status(400).json({ error: 'items must have title' });
      memoryItems = items as MemoryItem[];
      await mkdir(path.dirname(MEMORY_FILE), { recursive: true });
      await writeFile(MEMORY_FILE, JSON.stringify(memoryItems, null, 2), 'utf8');
      const archived = memoryItems.filter((m: MemoryItem) => (m as { archived?: boolean }).archived).length;
      res.json({ items: memoryItems, stats: { background: memoryItems.length, archived, instructionFiles: 0 } });
    } catch (e) {
      res.status(400).json({ error: (e as Error).message });
    }
  });

  // ── 沙箱额外可信写目录（SandboxPanel 同步）────────
  app.get('/api/sandbox/status', async (_req, res) => {
    try {
      res.json(await sandboxStatus());
    } catch (e) {
      res.status(503).json({ error: String(e) });
    }
  });
  // Load the persisted sandbox config once. An explicit TRHA_SANDBOX wins;
  // otherwise the saved `enabled` flag decides. The cached view also feeds
  // defaultSandboxScope so /sandbox policy/scratch take effect.
  void readSandboxConfig().then(cfg => {
    setSandboxConfigRuntime(cfg);
    const envExplicit = (process.env.TRHA_SANDBOX ?? '').trim() !== '';
    setSandboxEnabledRuntime(envExplicit ? sandboxEnabled() : cfg.enabled);
  }).catch(() => {});

  app.get('/api/sandbox/config', async (_req, res) => {
    try {
      const cfg = await readSandboxConfig();
      // `enabled` reports the effective switch (env/config + runtime PUT).
      res.json({ ...cfg, enabled: sandboxEnabled() });
    } catch (e) {
      res.status(503).json({ error: String(e) });
    }
  });
  app.put('/api/sandbox/config', async (req, res) => {
    try {
      const patch: Partial<SandboxConfigView> = {};
      if (typeof req.body?.enabled === 'boolean') patch.enabled = req.body.enabled;
      if (typeof req.body?.policy === 'string') patch.policy = req.body.policy;
      if (typeof req.body?.network === 'string') patch.network = req.body.network;
      if (typeof req.body?.scratch === 'string') patch.scratch = req.body.scratch;
      res.json(await writeSandboxConfig(patch));
    } catch (e) {
      res.status(503).json({ error: String(e) });
    }
  });
  app.get('/api/sandbox/write-roots', (_req, res) => {
    res.json({ roots: extraWriteRoots });
  });
  app.put('/api/sandbox/write-roots', (req, res) => {
    const roots = Array.isArray(req.body?.roots) ? req.body.roots.filter((x: unknown) => typeof x === 'string') : [];
    extraWriteRoots = roots;
    res.json({ roots: extraWriteRoots });
  });

  // ── Agent presets ─────────────────────────────────────────────────────
  // One definition for every shell: Desktop used to hold these inline and the
  // TUI could only guess. `?id=` resolves a single preset (404 when unknown, so
  // `--agent-preset <typo>` can be rejected instead of silently falling back).
  app.get('/api/agent/presets', (req, res) => {
    const id = typeof req.query.id === 'string' ? req.query.id : undefined;
    if (id !== undefined) {
      const preset = getAgentPreset(id);
      if (!preset) return res.status(404).json({ error: `unknown agent preset "${id}"` });
      return res.json({ default: DEFAULT_AGENT_PRESET, preset });
    }
    res.json({ default: DEFAULT_AGENT_PRESET, presets: listAgentPresets() });
  });

  // ── Service status (sidebar: LSP / MCP) ───────────────────────────────
  // Balance is a *read-only* query: DeepSeek documents no rate limit for it and
  // it costs nothing, so refusing calls would be wrong — the TUI refreshes it
  // on every turn, and a 429 would freeze the displayed value at a stale
  // number. Cache instead: repeat calls inside the TTL are served locally, so a
  // polling script cannot hammer the provider while event-driven refreshes keep
  // working.
  const BALANCE_TTL_MS = 10_000;
  let balanceCache: { at: number; value: Awaited<ReturnType<typeof fetchBalance>> } | null = null;
  app.get('/api/balance', async (_req, res) => {
    const now = Date.now();
    if (balanceCache && now - balanceCache.at < BALANCE_TTL_MS) {
      return res.json(balanceCache.value);
    }
    try {
      const value = await fetchBalance();
      balanceCache = { at: Date.now(), value };
      res.json(value);
    } catch (e) {
      res.status(503).json({ error: String(e) });
    }
  });

  // ── Voice transcription (MiMo ASR contract) ───────────────────────────
  // This one *is* metered (an ASR call per request), so a sliding window is the
  // right control: sustained hammering is a cost attack, not a UI refresh.
  const transcribeLimit = rateLimit(60_000, 10);
  app.post('/api/transcribe', async (req, res) => {
    if (!transcribeLimit()) {
      return res.status(429).json({ error: 'too many transcription requests; retry in a minute' });
    }
    const file = typeof req.body?.path === 'string' ? req.body.path.trim() : '';
    if (!file) return res.status(400).json({ error: 'path is required' });
    try {
      res.json({ text: await transcribeWav(file) });
    } catch (e) {
      if (e instanceof AsrNotConfigured) {
        return res.status(503).json({ error: (e as Error).message });
      }
      res.status(502).json({ error: String(e) });
    }
  });

  app.get('/api/mcp/status', async (_req, res) => {
    try {
      res.json(await mcpStatus());
    } catch (e) {
      res.status(500).json({ error: String(e) });
    }
  });
  app.get('/api/lsp/status', (_req, res) => {
    res.json(lspStatus());
  });

  app.get('/api/permissions', (_req, res) => {
    res.json({ rules: getPermissionRules() });
  });
  app.put('/api/permissions', (req, res) => {
    try {
      const body = Array.isArray(req.body) ? req.body
        : Array.isArray(req.body?.rules) ? req.body.rules : null;
      if (!body) return res.status(400).json({ error: 'Expected {rules: [...]} or [...]' });
      setPermissionRules(body);
      compileRules();
      res.json({ rules: getPermissionRules() });
    } catch (e) {
      res.status(400).json({ error: (e as Error).message });
    }
  });

  app.get('/api/providers', (_req, res) => { void forwardToKernel(res, 'GET', '/providers'); });
  app.get('/api/providers/protocols', (_req, res) => { void forwardToKernel(res, 'GET', '/providers/protocols'); });
  app.post('/api/providers', (req, res) => { void forwardToKernel(res, 'POST', '/providers', req.body); });
  app.post('/api/providers/probe', (req, res) => { void forwardToKernel(res, 'POST', '/providers/probe', req.body); });
  app.post('/api/providers/check', (req, res) => { void forwardToKernel(res, 'POST', '/providers/check', req.body); });
  app.post('/api/providers/remove', (req, res) => { void forwardToKernel(res, 'POST', '/providers/remove', req.body); });
  app.post('/api/providers/edit', (req, res) => { void forwardToKernel(res, 'POST', '/providers/edit', req.body); });
  app.post('/api/providers/websearch', (req, res) => { void forwardToKernel(res, 'POST', '/providers/websearch', req.body); });
  app.post('/api/providers/thinking', (req, res) => { void forwardToKernel(res, 'POST', '/providers/thinking', req.body); });
  app.post('/api/providers/in-use', (req, res) => { void forwardToKernel(res, 'POST', '/providers/in-use', req.body); });

  // ── Sessions ──────────────────────────────────────────────────────────

  const sessions = new Map<string, SchedulerSession>();

  if (config.stateDir) {
    // Synchronous on purpose: the server is already listening, and a restored
    // session that is not in the map yet answers 404 to a reconnecting host.
    try {
      for (const r of loadSessionsSync(config.stateDir)) {
        sessions.set(r.sessionId, {
          id: r.sessionId,
          mode: r.mode,
          messages: r.messages as SessionMessage[],
          pendingApproval: r.pendingApproval,
          createdAt: new Date(r.createdAt),
          // v2 fields; absent in v1 files, hence the defaults
          ...(Array.isArray(r.todos) ? { todos: r.todos as Todo[] } : {}),
          ...(r.goal !== undefined ? { goal: r.goal as Goal | null } : {}),
          ...(Array.isArray(r.schedules) ? { schedules: r.schedules as Schedule[] } : {}),
          ...(r.pendingQuestion !== undefined
            ? { pendingQuestion: r.pendingQuestion as PendingQuestion | null } : {}),
          ...(Array.isArray(r.presentations)
            ? { presentations: r.presentations as Array<{ card: string; at: string }> } : {}),
          ...(Array.isArray(r.teamTasks) ? { teamTasks: r.teamTasks as TeamTask[] } : {}),
          ...(typeof r.parentId === 'string' ? { parentId: r.parentId } : {}),
          ...(typeof r.cwd === 'string' ? { cwd: r.cwd } : {}),
          ...(typeof r.title === 'string' ? { title: r.title } : {}),
          ...(Array.isArray(r.tags) ? { tags: r.tags as string[] } : {}),
          ...(typeof r.permissionMode === 'string'
            ? { permissionMode: r.permissionMode as PermissionMode } : {}),
          ...(typeof r.planMode === 'boolean' ? { planMode: r.planMode } : {}),
          ...(r.yoloRestore !== undefined
            ? { yoloRestore: r.yoloRestore as PermissionMode | null } : {}),
        });
        // A restarted kernel may have an empty session map; re-register so the
        // restored conversation keeps its projections and FSM state going.
        // `startKernelSession` is idempotent, so a kernel that already loaded
        // this session from its state dir answers `resumed: true` and keeps
        // the FSM it restored.
        void bridge.startKernelSession(r.sessionId, r.mode).catch(e =>
          console.error(`kernel session restore ${r.sessionId}:`, e));
      }
    } catch (e) {
      console.error('session restore failed:', e);
    }
  }

  // optional disk persistence (G2): no-op without stateDir
  // Returns the write so a caller that must be durable (a tool that just
  // mutated session state) can await it; the rest fire-and-forget.
  const persistSession = (session: SchedulerSession): Promise<void> => {
    if (!config.stateDir) return Promise.resolve();
    return saveSession(config.stateDir, session).catch(e => {
      console.error(`persist session ${session.id}:`, e);
    });
  };

  app.post('/api/session/start', (req, res) => {
    const mode = req.body.mode || 'standard';
    if (!MODES[mode]) return res.status(400).json({ error: `Unknown mode: ${mode}` });
    // Headless/CI callers can open a session directly in a posture; the
    // default stays the safe read-only (Shift+Tab / /mode change it later).
    const requested = req.body.permissionMode;
    if (requested !== undefined && !MODE_CYCLE.includes(requested)) {
      return res.status(400).json({ error: `Unknown permissionMode: ${requested}` });
    }
    const posture = (requested as PermissionMode | undefined) ?? 'read-only';
    const planMode = posture === 'plan';
    const approval: PermissionMode = planMode ? 'ask' : posture;
    const sessionId = `session-${Date.now()}`;
    const askTimeout = typeof req.body.askTimeout === 'number' && req.body.askTimeout > 0
      ? Math.round(req.body.askTimeout * 1000)
      : undefined;
    // Per-session workspace.  The scheduler is shared by every client (TUI,
    // desktop, web), so a single process-wide WORKSPACE cannot serve people
    // working in different projects: whichever client started the scheduler
    // would decide the workspace for all of them.  The caller knows its own
    // directory, so let it say — validated here, because this value becomes
    // the tool layer's read/write boundary.
    const requestedCwd = typeof req.body.cwd === 'string' ? req.body.cwd.trim() : '';
    let sessionCwd: string | undefined;
    if (requestedCwd) {
      if (!path.isAbsolute(requestedCwd)) {
        return res.status(400).json({ error: 'cwd must be an absolute path' });
      }
      const abs = path.resolve(requestedCwd);
      if (abs === path.parse(abs).root) {
        return res.status(400).json({ error: 'cwd must not be the filesystem root' });
      }
      if (!existsSync(abs)) {
        return res.status(400).json({ error: `cwd does not exist: ${abs}` });
      }
      sessionCwd = abs;
    }
    const created = {
      id: sessionId, mode, messages: [] as SessionMessage[],
      pendingApproval: null, createdAt: new Date(),
      permissionMode: approval, planMode,
      yoloRestore: null as PermissionMode | null,
      ...(sessionCwd !== undefined ? { cwd: sessionCwd, workspaceRoot: sessionCwd } : {}),
      ...(askTimeout !== undefined ? { askTimeoutMs: askTimeout } : {}),
    };
    sessions.set(sessionId, created);
    persistSession(created);
    // Register the same id kernel-side so projections (t6state/constraint) and
    // the FSM have somewhere to live; failure is logged, not fatal.
    void bridge.startKernelSession(sessionId, mode).catch(e =>
      console.error(`kernel session create ${sessionId}:`, e));
    events.emit('session:created', { sessionId, mode });
    emitSafe(plugins.emitSessionCreate(sessionId));
    res.json({ sessionId, mode });
  });

  app.get('/api/session/:id', (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    res.json(session);
  });

  app.get('/api/session/:id/messages', (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    res.json({ messages: session.messages });
  });

  app.delete('/api/session/:id', (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    sessions.delete(req.params.id);
    // The session may own a browser tab; leaving it alive would leak a page per
    // deleted conversation.
    void browserClose(req.params.id).catch(() => {});
    if (config.stateDir) {
      void removeSessionFile(config.stateDir, req.params.id).catch(() => {});
    }
    // Tell the kernel too: it holds the session and a snapshot on disk, and
    // an undeleted snapshot would resurrect this conversation after restart.
    void bridge.deleteKernelSession(req.params.id).catch(e =>
      console.error(`kernel session delete ${req.params.id}:`, e));
    events.emit('session:deleted', { sessionId: req.params.id });
    emitSafe(plugins.emitSessionDelete(req.params.id));
    res.json({ ok: true, sessionId: req.params.id });
  });

  app.get('/api/sessions', (_req, res) => {
    res.json(Array.from(sessions.values()));
  });

  // ── Sandbox scopes (T2.6: agent tree + isolation) ─────────────────────
  app.get('/api/sandbox/scopes', async (_req, res) => {
    try {
      const cfg = await readSandboxConfig();
      const enabled = sandboxEnabled();
      res.json({
        scopes: Array.from(sessions.values()).map(s => ({
          id: s.id,
          parent: s.parentId ?? null,
          depth: s.depth ?? 0,
          policy: s.parentId ? 'read-only' : cfg.policy,
          isolation: 'process',
          enabled,
          cwd: s.cwd ?? null,
        })),
      });
    } catch (e) {
      res.status(503).json({ error: String(e) });
    }
  });

  // Rename / tag a session.  Both fields are user-facing only (never part of
  // the model's history) and persisted alongside the rest of the state.
  app.post('/api/session/:id/meta', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    const body = req.body ?? {};
    if (typeof body.title === 'string') session.title = body.title.trim();
    if (Array.isArray(body.tags)) {
      session.tags = body.tags.filter((t: unknown): t is string => typeof t === 'string');
    }
    // Await the write: a restart on the same stateDir must see the metadata
    // (session-meta pins this; fire-and-forget lost it under load).
    await persistSession(session);
    res.json({ id: session.id, title: session.title ?? null, tags: session.tags ?? [] });
  });

  // Change the session's workspace.  This is the *human* channel: the model
  // has no tool that reaches it (its `cd` is clamped to the current
  // workspace), so an agent can never widen its own sandbox.  Only the
  // `/workspace` slash command — typed by a person — calls this.
  app.post('/api/session/:id/cwd', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    const raw = typeof req.body?.cwd === 'string' ? req.body.cwd.trim() : '';
    if (!raw || !path.isAbsolute(raw)) {
      return res.status(400).json({ error: 'cwd must be an absolute path' });
    }
    const abs = path.resolve(raw);
    if (abs === path.parse(abs).root) {
      return res.status(400).json({ error: 'cwd must not be the filesystem root' });
    }
    if (!existsSync(abs)) {
      return res.status(400).json({ error: `no such directory: ${abs}` });
    }
    session.cwd = abs;
    // Moving the workspace moves its root too: `cd` clamps to the root, so
    // leaving it behind would strand the session in the old project.
    session.workspaceRoot = abs;
    // Await: a restart on the same stateDir must see the new workspace.
    await persistSession(session);
    res.json({ cwd: session.cwd });
  });

  // ── Agent step ────────────────────────────────────────────────────────

  // Run one full agent step and return the (aggregated) reply text.
  // Shared by the plain /api/agent/step path and by the approval gate
  // after the host approves a pending plan.
  // ── Tool loop (Phase 3 K5) ─────────────────────────────────────────────
  // Host-side tool executions: read-only file access for now.  The kernel
  // emits assistant tool_calls; we execute them and feed results back as
  // tool messages until the model answers without tool calls.
  // Host-side tools live under the orchestration workspace so file mutations
  // cannot escape it.  Resolution order (see `workspace.ts`): TRHA_WORKSPACE,
  // then the nearest `.trha/workspace` marker walking *up* from the cwd (then
  // $HOME), then the nearest `.git` root, then a build manifest, and only then
  // the directory the scheduler was started in.  Without the upward walk a
  // scheduler launched from `packages/<pkg>` reported that subpackage as the
  // workspace — and the system prompt's `{{cwd}}` moved with it.
  const WORKSPACE = resolveWorkspace({
    env: process.env.TRHA_WORKSPACE,
    cwd: process.cwd(),
    home: process.env.HOME,
  });
  // The `bash` tool must really be bash: it is offered to the model under that
  // name, and a coding agent writes `[[ ]]`, arrays and `pipefail` without
  // thinking about it.  Previously this used Node's `exec` default, which is
  // `/bin/sh` on POSIX (dash on Debian) — those all failed.
  //
  // Deliberately NOT `bash -lc`: a *login* shell re-runs the profile, which
  // rebuilds PATH.  Measured on this repo's dev box, `bash -lc` swapped an
  // fnm-managed node v26.12.1 for the system v22.22.1 — a tool call must never
  // silently change the toolchain version.  `bash -c` keeps the inherited env
  // and still gives bash syntax.  The shell comes from Server/shell.ts; win32
  // keeps Node's default (`cmd.exe /d /s /c`).
  //
  // Contract unchanged: 120 s timeout, 4 MiB of output, `exit <code>` first.
  // Background jobs cannot outlive this process, so they are process-local on
  // purpose (the tool tells the model exactly that).
  const jobsBySession = new Map<string, Map<string, JobRecord>>();
  // Persistent terminals are process-local (a child cannot outlive us).
  const terminalsBySession = new Map<string, Map<string, Terminal>>();
  const terminalsFor = (sessionId: string): Map<string, Terminal> => {
    let m = terminalsBySession.get(sessionId);
    if (!m) { m = new Map(); terminalsBySession.set(sessionId, m); }
    return m;
  };

  const jobsFor = (sessionId: string): Map<string, JobRecord> => {
    let m = jobsBySession.get(sessionId);
    if (!m) { m = new Map(); jobsBySession.set(sessionId, m); }
    return m;
  };
  // bash runs with the workspace as cwd, so a missing directory would fail the
  // very first command; create it once at startup.
  void mkdir(WORKSPACE, { recursive: true }).catch(() => {});
  // 沙箱「允许写入路径」（设置页配置的额外可信写目录；限制放宽，默认仅工作区）
  let extraWriteRoots: string[] = [];
  const AGENT_TOOLS: BridgeToolSpec[] = toToolSpecs();
  // No round cap by default: a real fix loop (probe → compile → read error →
  // fix) legitimately takes dozens of rounds, and a hard limit abandons work
  // that was converging. The loop ends when the model stops calling tools; a
  // repeated identical call is what actually signals a stuck agent, so that is
  // what is guarded. Set TRHA_MAX_TOOL_ROUNDS to cap it anyway.
  const maxToolRounds = envCap('TRHA_MAX_TOOL_ROUNDS');
  const STUCK_REPEATS = 3;

  const emitToolLifecycle = async (
    sessionId: string, name: string, args: string[],
    status: 'running' | 'succeeded' | 'failed', startedAt?: number, error?: string,
    output?: string,
  ): Promise<void> => {
    const ev: ToolEvent = {
      name, args, status,
      ...(error !== undefined ? { error } : {}),
      ...(startedAt !== undefined ? { durationMs: Date.now() - startedAt } : {}),
      ...(output !== undefined ? { output } : {}),
    };
    events.emit('tool:update', { sessionId, ...ev });
    if (status === 'running') {
      emitSafe(plugins.emitToolCall(sessionId, name, args));
    }
  };

  const parseToolArgs = (c: ToolCallData): string[] => {
    try {
      const o = JSON.parse(c.arguments) as Record<string, unknown>;
      return Object.entries(o).map(([k, v]) => `${k}=${typeof v === 'string' ? v : JSON.stringify(v)}`);
    } catch {
      return [c.arguments];
    }
  };

  // Reads may leave the workspace: `bash` already can, so confining only the
  // read tool would buy no safety while breaking absolute paths that callers
  // legitimately use. Writes stay confined.
  // A provider requires each assistant(tool_calls) message to be answered by
  // one tool message per call id before anything else.  Incomplete groups
  // happen when the loop is interrupted, a tool is parked for approval, or a
  // tool throws; repairing keeps the conversation usable instead of 400-ing
  // forever ("messages following tool_calls message").
  const repairToolPairs = (messages: SessionMessage[]): SessionMessage[] => {
    const out: SessionMessage[] = [];
    for (let i = 0; i < messages.length; i++) {
      const m = messages[i];
      if (!m) continue;
      out.push(m);
      if (m.role !== 'assistant') continue;
      const calls = (m as { tool_calls?: Array<{ id?: string }> }).tool_calls;
      if (!Array.isArray(calls) || calls.length === 0) continue;
      const answered = new Set<string>();
      let j = i + 1;
      while (j < messages.length && messages[j]?.role === 'tool') {
        const id = (messages[j] as { tool_call_id?: string }).tool_call_id;
        if (typeof id === 'string') answered.add(id);
        out.push(messages[j] as SessionMessage);
        j++;
      }
      for (const c of calls) {
        if (typeof c?.id === 'string' && !answered.has(c.id)) {
          out.push({
            role: 'tool', tool_call_id: c.id,
            content: 'ERROR: interrupted before the tool produced a result',
          });
        }
      }
      i = j - 1;
    }
    return out;
  };

  // Everyday shell probes that only read.  A broad `Bash(command:*)` ask rule
  // must not turn `curl`/`ls`/`cat` into an approval prompt: that is the
  // "tool cannot be called" experience users hit on a simple weather query.
  const isReadOnlyShell = (cmd: string): boolean =>
    cmd.length > 0
    && !/[;>]|&&|\brm\b|\bsudo\b|\bmv\b|\bcp\b|\bchmod\b|\bkill\b|\btee\b|\bdd\b/.test(cmd)
    && /^(ls|cat|head|tail|wc|pwd|date|whoami|uname|which|echo|printf|curl|wget|rg|grep|find|file|stat|du|df|env|printenv|git\s+(status|log|diff|show|branch|remote|rev-parse))\b/i.test(cmd);

  const executeTool = async (c: ToolCallData, sessionId?: string): Promise<string> => {
    let argsObj: Record<string, unknown> = {};
    try {
      argsObj = JSON.parse(c.arguments) as Record<string, unknown>;
    } catch {
      return `ERROR: malformed arguments for ${c.name}`;
    }
    // Canonical names first, then the legacy aliases: one implementation per
    // capability, so the schema and the executor cannot drift apart.
    const name = canonicalToolName(c.name);
    // One cwd per call: a session may have switched directories, and every fs
    // operation must agree on which one it is.
    const cwd = (sessionId ? sessions.get(sessionId)?.cwd : undefined) ?? WORKSPACE;
    // 权限规则引擎 + 会话姿态：deny 永远优先；read-only/plan 只放行只读工具；
    // ask 模式要求确认；YOLO 跳过 ask 规则（Reasonix 的 danger-full-access）。
    const permSession = sessionId ? sessions.get(sessionId) : undefined;
    const posture: PermissionMode = permSession?.planMode
      ? 'plan'
      // No session (direct tool execution in tests / approval replay): keep
      // the old rule-engine behaviour instead of the session default.
      : (permSession?.permissionMode ?? 'auto');
    const verdict = applyPermissionMode(posture, name, decidePermission(name, argsObj));
    if (verdict.action === 'deny') return `ERROR: ${verdict.reason}`;
    if (verdict.action === 'ask') {
      const cmd = typeof argsObj.command === 'string' ? argsObj.command.trim() : '';
      if (!(name === 'bash' && isReadOnlyShell(cmd))) {
        return `REQUIRE_APPROVAL: ${verdict.reason}`;
      }
    }
    // Registered tools win over the core chain as well, so a preset or an
    // external plugin can replace `bash`/`read`/`write`/`grep`/`glob`. The chain
    // below stays as the fallback for everything not migrated yet.
    {
      const registeredCore = resolveTool(name);
      if (registeredCore?.handler) {
        const session = sessionId ? sessions.get(sessionId) : undefined;
        if (!session) return `ERROR: ${name} needs a live session`;
        const out = await renderToolValue(registeredCore, argsObj, {
          workspace: WORKSPACE,
          state: session,
          jobs: jobsFor(sessionId!),
          sessionId: sessionId!,
          sessionCwd: cwd,
          writeRoots: extraWriteRoots,
          agents: agentHooksFor(session),
        }).catch((e: unknown) => `ERROR: ${String(e)}`);
        if (!out.startsWith('UNCHANGED:')) await persistSession(session);
        return out;
      }
    }

    if (name === 'bash') {
      // Migrated to the registry (full DSH contract); the core-chain pre-check
      // above resolves it before this line is ever reached.
    }
    if (name === 'read') {
      // Migrated to the registry (full DSH contract); the core-chain pre-check
      // above resolves it before this line is ever reached.
    }
    if (name === 'write' || name === 'append_file') {
      // Migrated to the registry (full DSH contract); the core-chain pre-check
      // above resolves them before this line is ever reached.
    }
    if (name === 'edit') {
      // Migrated to the registry (full DSH contract); the core-chain pre-check
      // above resolves it before this line is ever reached.
    }
    if (name === 'glob') {
      // Migrated to the registry (full DSH contract); the core-chain pre-check
      // above resolves it before this line is ever reached.
    }
    if (name === 'grep') {
      // Migrated to the registry (full DSH contract); the core-chain pre-check
      // above resolves it before this line is ever reached.
    }
    if (isStandardTool(name)) {
      const session = sessionId ? sessions.get(sessionId) : undefined;
      if (!session) return `ERROR: ${name} needs a live session`;
      // A tool failure is a tool *result*: letting it reject would kill the
      // turn (and leave the model with no way to recover).
      const out = await runStandardTool(name, argsObj, {
        workspace: WORKSPACE,
        state: session,
        jobs: jobsFor(sessionId!),
        sessionId: sessionId!,
        sessionCwd: cwd,
        writeRoots: extraWriteRoots,
        agents: agentHooksFor(session),
      }).catch((e: unknown) => `ERROR: ${String(e)}`);
      if (out !== null) {
        // todos/goal/schedules belong to the session: persist them with it,
        // and wait — a crash right after the tool must not lose the update.
        // An UNCHANGED result is the exception: nothing moved, so nothing to
        // write.
        if (!out.startsWith('UNCHANGED:')) await persistSession(session);
        return out;
      }
    }

    if (isExtraTool(name)) {
      const session = sessionId ? sessions.get(sessionId) : undefined;
      if (!session) return `ERROR: ${name} needs a live session`;
      const host: ExtraHost = {
        workspace: WORKSPACE,
        state: session,
        jobs: jobsFor(sessionId!),
        sessionId: sessionId!,
        agents: agentHooksFor(session),
        cwd: () => session.cwd ?? WORKSPACE,
        workspaceRoot: () => session.workspaceRoot ?? WORKSPACE,
        setCwd: (dir: string) => {
          session.cwd = dir;
          void persistSession(session);
        },
        terminals: terminalsFor(sessionId!),
        kernelEvents: id => bridge.getSessionEvents(id),
        allSessions: () => [...sessions.values()].map(s2 => ({
          id: s2.id,
          messages: s2.messages.map(m => ({ role: m.role, content: m.content })),
        })),
        models: () => models.map(m => ({ name: m.name, description: m.description })),
        plugins: {
          list: () => plugins.listPlugins().map(p => ({
            name: p.name,
            enabled: true,
            hooks: Object.keys(p).filter(k => k.startsWith('on')),
          })),
          inspect: (n: string) => {
            const p = plugins.getPlugin(n);
            return p ? { name: p.name, version: p.version, hooks: Object.keys(p).filter(k => k.startsWith('on')) } : undefined;
          },
        },
        spawnFresh: (task, label) => spawnAgent(session, task, label),
        extraWriteRoots: () => extraWriteRoots,
      };
      const out = await runExtraTool(name, argsObj, host).catch((e: unknown) => `ERROR: ${String(e)}`);
      if (out !== null) {
        await persistSession(session);
        return out;
      }
    }
    return `ERROR: unknown tool: ${c.name}`;
  };


  // Tool service: single source of truth exposed on ctx.tools (list/execute)
  // so plugins can read the tool set by key instead of importing internals.
  plugins.registerService('tools', {
    list: () => AGENT_TOOLS,
    execute: executeTool,
  }, ['tools:list', 'tools:execute']);
  // read-only session view (plugins observe session state by key)
  plugins.registerService('sessions', {
    get: (id: string) => sessions.get(id),
    has: (id: string) => sessions.has(id),
    list: () => Array.from(sessions.values()).map(s => ({ id: s.id, mode: s.mode })),
  }, ['sessions:get', 'sessions:list']);

  // Run one full agent step: loop tools until the model replies in plain
  // text (or the round budget is exhausted).
  // Last step's kernel causal-constraint verdict (D-1), surfaced to the UI via
  // /api/agent/step so the frontend can show whether this reply is
  // constraint-protected (pass / warn) — P3 wiring.
  let stepConstraint: Record<string, unknown> | undefined;

  const runStep = async (
    session: SchedulerSession,
    message: string,
    target: TurnTarget = {},
    onDelta?: (text: string) => void,
  ): Promise<string> => {
    session.lastRequest = { message, ...target };
    const mode = MODES[session.mode] ?? MODES.standard;
    // Plugins may intercept the whole step (approval / short-circuit) by
    // bailing on 'agent:step:before' with a reply.
    const intercepted = await plugins.runBail('agent:step:before', message);
    if (typeof intercepted === 'string') {
      session.messages.push({ role: 'user', content: message });
      events.emit('agent:message', { sessionId: session.id, role: 'user', content: message });
      session.messages.push({ role: 'assistant', content: intercepted });
      events.emit('agent:message', { sessionId: session.id, role: 'assistant', content: intercepted });
      persistSession(session);
      return intercepted;
    }
    // Plugins may rewrite the tool set offered to the model.
    const allTools = (plugins.service('tools') as { list(): BridgeToolSpec[] }).list();
    // An agent definition can narrow the tool set. Without one, behaviour is
    // unchanged (every tool the mode exposes).
    const toolsBase = target.toolsAllow?.length
      ? allTools.filter(t => target.toolsAllow!.includes(t.name))
      : allTools;
    const toolsCfg = (await plugins.runWaterfall('agent:tools', toolsBase)) as BridgeToolSpec[];
    session.messages.push({ role: 'user', content: message });
    events.emit('agent:message', { sessionId: session.id, role: 'user', content: message });
    emitSafe(plugins.emitMessageSend(session.id, { role: 'user', content: message }));

    let lastCallKey = '';
    let sameCallRepeats = 0;
    for (let round = 0; round < maxToolRounds; round++) {
      // /steer: instructions injected while the turn runs take effect at the
      // next model call, without starting a new turn.
      if (session.steer && session.steer.length > 0) {
        for (const steer of session.steer.splice(0)) {
          session.messages.push({ role: 'user', content: steer });
          events.emit('agent:message', { sessionId: session.id, role: 'user', content: steer });
          emitSafe(plugins.emitMessageSend(session.id, { role: 'user', content: steer }));
        }
        persistSession(session);
      }
      if (session.abortRequested) {
        session.abortRequested = false;
        const stopped = '(interrupted)';
        session.messages.push({ role: 'assistant', content: stopped });
        events.emit('agent:message', { sessionId: session.id, role: 'assistant', content: stopped });
        await persistSession(session);
        return stopped;
      }
      let response;
      // "Model-visible means logged": every model request is observable
      // before it is sent, so a transcript/plugin can reconstruct what the
      // model saw.
      events.emit('agent:model-request', {
        sessionId: session.id,
        round,
        messageCount: session.messages.length,
        toolCount: toolsCfg.length,
      });
      try {
        // Context governance runs immediately before the request, so the
        // provider sees exactly what was measured.
        const governed = govern(session.messages, session.lastPromptTokens ?? 0, governanceConfig());
        if (governed.prefixChanged) {
          session.messages = governed.messages;
          session.prefixResets = (session.prefixResets ?? 0) + 1;
          session.lastMaintenance = { trigger: governed.trigger, savedTokens: governed.savedTokens };
          events.emit('agent:context', {
            sessionId: session.id, trigger: governed.trigger,
            savedTokens: governed.savedTokens, prefixChanged: true,
          });
          persistSession(session);
        }
        // Repair an incomplete tool_calls group before it reaches the provider
        // (interrupt / approval park / throwing tool).
        session.messages = repairToolPairs(session.messages);
        const promptMessages = await withSystemPrompt(
          mode, target.model ?? 'deepseek-flash',
          session.cwd ?? WORKSPACE, session.messages,
          target.reasoningLanguage,
          target.extraInstructions,
        );
        const request = {
          messages: promptMessages,
          tools: toolsCfg,
          model: target.model, provider: target.provider,
          genParams: target.genParams,
          // Same key the kernel session was registered under, so this round
          // updates projections/FSM instead of running statelessly.
          sessionId: session.id,
        };
        // A kernel without the streaming endpoint — or a wire that cannot
        // stream — still answers: fall back to the blocking call instead of
        // failing the whole step.  Transient provider failures (429 / 5xx /
        // timeout) are retried once or twice before the offline fallback.
        const callModel = () => onDelta
          ? bridge.queryModelStream(
              request,
              onDelta,
              text => events.emit('agent:reasoning', { sessionId: session.id, reasoning: text }),
            ).catch(() => bridge.queryModel(request))
          : bridge.queryModel(request);
        response = await withRetry(callModel, (attempt, delayMs, reason) => {
          events.emit('agent:retry', {
            sessionId: session.id, attempt, delayMs, reason,
          });
        });
        if (response.constraint) stepConstraint = response.constraint;
        if (response.usage?.promptTokens !== undefined) {
          session.lastPromptTokens = response.usage.promptTokens;
          session.cacheHitTokens = (session.cacheHitTokens ?? 0) + (response.usage.cacheHitTokens ?? 0);
          session.cacheMissTokens = (session.cacheMissTokens ?? 0) + (response.usage.cacheMissTokens ?? 0);
          session.completionTokens = (session.completionTokens ?? 0) + (response.usage.completionTokens ?? 0);
        }
      } catch {
        // Kernel unreachable: demo tool lifecycle + mode-context echo
        // (kept for Phase 2 S2 tool-event tests and offline development).
        const demo: ToolEvent = { name: 'bash', args: ['echo demo-tool'], status: 'running' };
        events.emit('tool:update', { sessionId: session.id, ...demo });
        emitSafe(plugins.emitToolCall(session.id, demo.name, demo.args));
        const started = Date.now();
        await new Promise(r => setTimeout(r, 30));
        events.emit('tool:update', {
          sessionId: session.id, ...demo,
          status: 'succeeded', durationMs: Date.now() - started,
        });
        const reply = mode.ptc.enabled
          ? `[PTC] run_code(${message.slice(0, 50)}...)`
          : `[${session.mode}] Received: ${message}`;
        session.messages.push({ role: 'assistant', content: reply });
        events.emit('agent:message', { sessionId: session.id, role: 'assistant', content: reply });
        persistSession(session);
        return reply;
      }

      const calls = response.toolCalls ?? [];
      if (calls.length === 0) {
        const reply = response.reply;
        session.messages.push({ role: 'assistant', content: reply });
        events.emit('agent:message', { sessionId: session.id, role: 'assistant', content: reply });
        persistSession(session);
        return reply;
      }

      // Record the assistant's tool_calls, execute each tool, feed results
      // back as tool messages, then let the model continue.
      // The assistant turn goes back into the history next round, and a
      // provider validates those arguments as JSON — so store a normalised
      // form rather than whatever the model emitted.
      const normaliseArgs = (raw: string): string => {
        try { return JSON.stringify(JSON.parse(raw)); } catch { return '{}'; }
      };
      session.messages.push({
        role: 'assistant', content: response.reply,
        // Thinking mode requires the chain back on the next request; without it
        // the provider answers 400 and the whole loop dies mid-task.
        ...(response.reasoningContent ? { reasoning_content: response.reasoningContent } : {}),
        ...(response.reasoningSignature ? { reasoning_signature: response.reasoningSignature } : {}),
        tool_calls: calls.map(c => ({
          id: c.id, type: 'function',
          function: { name: c.name, arguments: normaliseArgs(c.arguments) },
        })),
      });
      const callKey = calls.map(c => `${c.name}:${c.arguments}`).join('|');
      sameCallRepeats = callKey === lastCallKey ? sameCallRepeats + 1 : 1;
      lastCallKey = callKey;
      if (sameCallRepeats >= STUCK_REPEATS) {
        const stuck = `(stopped: the same tool call repeated ${sameCallRepeats} times)`;
        session.messages.push({ role: 'assistant', content: stuck });
        events.emit('agent:message', { sessionId: session.id, role: 'assistant', content: stuck });
        persistSession(session);
        return stuck;
      }
      for (const call of calls) {
        const started = Date.now();
        await emitToolLifecycle(session.id, call.name, parseToolArgs(call), 'running');
        const output = await executeTool(call, session.id).catch(
          (e: unknown) => `ERROR: ${String(e)}`,
        );
        // ask 权限规则：暂停执行并发起确认（批准后重放该工具）
        if (output.startsWith('REQUIRE_APPROVAL:')) {
          await emitToolLifecycle(session.id, call.name, parseToolArgs(call), 'failed', started, output);
          // Park the call, but keep the history valid: the provider rejects an
          // assistant(tool_calls) message that has no tool reply.  The approval
          // replay replaces this placeholder with the real output.
          session.messages.push({
            role: 'tool', tool_call_id: call.id,
            content: 'ERROR: awaiting user approval',
          });
          session.pendingApproval = { message: output, ...target };
          session.pendingApprovalAt = new Date().toISOString();
          (session as { pendingToolCall?: ToolCallData | undefined }).pendingToolCall = call;
          events.emit('agent:plan', { sessionId: session.id, status: 'awaiting_approval', message: output });
          return `awaiting_approval: ${output}`;
        }
        // A provider requires every tool_calls message to be followed by a tool
        // message per call id before anything else. So the tool result goes in
        // first, and *then* any marker-derived message (a card, a question).
        const failed = output.startsWith('ERROR');
        await emitToolLifecycle(session.id, call.name, parseToolArgs(call),
          failed ? 'failed' : 'succeeded', started, failed ? output : undefined,
          failed ? undefined : outputPreview(output));
        session.messages.push({ role: 'tool', tool_call_id: call.id, content: output });
        // `UNCHANGED:` means the tool declined to modify state; writing the
        // session anyway would churn the file (and its mtime) for nothing.
        if (!output.startsWith('UNCHANGED:')) await persistSession(session);

        if (output.startsWith('PRESENT:')) {
          const card = output.slice('PRESENT:'.length);
          // UI-only: pushing it into the transcript would put a synthetic
          // assistant turn in front of the model on the next request.
          session.presentations = [
            ...(session.presentations ?? []),
            { card, at: new Date().toISOString() },
          ];
          events.emit('agent:present', { sessionId: session.id, card });
        }
        // A tool that needs a human must end the turn: continuing would mean
        // inventing the answer inside the same loop. The tool result is already
        // in the history, so the next request stays valid.
        if (output.startsWith('WAITING_FOR_INPUT:')) {
          const question = output.slice('WAITING_FOR_INPUT:'.length).trim();
          events.emit('agent:question', { sessionId: session.id, question });
          await persistSession(session);
          return question;
        }
        if (output.startsWith('WAITING_FOR_APPROVAL:')) {
          const plan = output.slice('WAITING_FOR_APPROVAL:'.length).trim();
          session.pendingApproval = { message: plan, ...target };
          void bridge.requestApproval(session.id, plan).catch(e =>
            console.error(`kernel approval request ${session.id}:`, e));
          events.emit('agent:plan', { sessionId: session.id, status: 'awaiting_approval', message: plan });
          await persistSession(session);
          return plan;
        }
      }
    }

    const exhausted = Number.isFinite(maxToolRounds)
      ? `(tool loop stopped at the configured ${maxToolRounds}-round cap)`
      : '(tool loop ended without a final answer)';
    session.messages.push({ role: 'assistant', content: exhausted });
    events.emit('agent:message', { sessionId: session.id, role: 'assistant', content: exhausted });
    persistSession(session);
    return exhausted;
  };

  app.post('/api/agent/step', async (req, res) => {
    const { sessionId, message, requireApproval, provider, model, temperature, topP, maxTokens, effort, askTimeout } = req.body;
    // The shell sends the reasoning language on every step (auto = follow the
    // interface language, resolved shell-side).  It used to be dropped here,
    // so /reasoning-language had no effect at all.
    const reasoningLanguage = reasoningLanguageTag(req.body.reasoningLanguage);
    const genParams = temperature !== undefined || topP !== undefined || maxTokens !== undefined || effort !== undefined
      ? { temperature, topP, maxTokens, effort }
      : undefined;
    const session = sessions.get(sessionId);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    if (typeof message !== 'string' || message.trim() === '') {
      return res.status(400).json({ error: 'Missing message' });
    }
    // A new message is also an answer: do not leave a stale question parked.
    session.pendingQuestion = null;

    // Approval gate: hold the request until the host decides.
    //
    // The kernel is the gate of record (it parks the session in
    // `awaiting_approval`, which it persists and enforces as a barrier), so
    // tell it first. A kernel that is down must not break the shell, hence the
    // local `pendingApproval` stays authoritative for the response shape.
    if (typeof askTimeout === 'number' && askTimeout > 0) {
      session.askTimeoutMs = Math.round(askTimeout * 1000);
    }
    if (requireApproval) {
      session.pendingApproval = { message, provider, model, genParams, reasoningLanguage };
      session.pendingApprovalAt = new Date().toISOString();
      void bridge.requestApproval(sessionId, message).catch(e =>
        console.error(`kernel approval request ${sessionId}:`, e));
      events.emit('agent:plan', { sessionId, status: 'awaiting_approval', message });
      return res.json({ status: 'awaiting_approval', pending: { message }, mode: session.mode });
    }

    // A regular step supersedes a stale gate. Resolve it kernel-side as a
    // rejection: otherwise the kernel's barrier would keep refusing every
    // later step for this session.
    if (session.pendingApproval) {
      void bridge.decideApproval(session.id, false).catch(e =>
        console.error(`kernel approval release ${session.id}:`, e));
    }
    session.pendingApproval = null;
    // A3: stream the answer to whoever listens on this session's SSE channel.
    // Serialized per session: two concurrent steps would interleave their
    // messages and produce a transcript the provider rejects.
    const beforeTokens = {
      hit: session.cacheHitTokens ?? 0,
      miss: session.cacheMissTokens ?? 0,
      comp: session.completionTokens ?? 0,
    };
    const reply = await withSessionLock(session.id, () =>
      runTurn(session, message, { provider, model, genParams, reasoningLanguage },
        text => events.emit('agent:delta', { sessionId: session.id, text })));
    // Usage echo for shell footers: `promptTokens` is the provider's own
    // last prompt size (in, incl. cache), the deltas are this turn's out,
    // `cumulativeTokens` is the session total (cacheHit+cacheMiss+completion).
    const usage = {
      promptTokens: session.lastPromptTokens ?? 0,
      completionTokens: (session.completionTokens ?? 0) - beforeTokens.comp,
      cacheHitTokens: (session.cacheHitTokens ?? 0) - beforeTokens.hit,
      cacheMissTokens: (session.cacheMissTokens ?? 0) - beforeTokens.miss,
      cumulativeTokens: (session.cacheHitTokens ?? 0) + (session.cacheMissTokens ?? 0)
        + (session.completionTokens ?? 0),
    };
    res.json({
      reply, messages: session.messages, mode: session.mode, usage,
      ...(stepConstraint ? { constraint: stepConstraint } : {}),
    });
  });

  // ── Session permission posture (Shift+Tab cycle / Ctrl+Y YOLO) ────────
  //
  // The posture is session state, not a global switch: two sessions may run
  // under different permissions.  `planMode` is a separate flag so Ctrl+Y in
  // Plan can toggle YOLO without silently leaving the plan (Reasonix parity).
  const modeState = (session: SchedulerSession) => {
    const mode = session.permissionMode ?? 'read-only';
    return {
      mode,
      // Plan is its own posture in the cycle (read-only → ask → auto → YOLO →
      // plan); the underlying approval mode stays ask so tools still confirm.
      label: session.planMode ? 'Plan' : modeLabel(mode),
      planMode: session.planMode === true,
      yoloRestore: session.yoloRestore ?? null,
      cycle: MODE_CYCLE,
    };
  };

  app.get('/api/session/:id/mode', (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    res.json(modeState(session));
  });

  // ── Workflow templates (/workflow) ────────────────────────────────────
  app.get('/api/workflows', (_req, res) => {
    res.json({ workflows: WORKFLOW_TEMPLATES.map(w => ({ name: w.name, description: w.description })) });
  });
  app.post('/api/session/:id/workflow', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'no session' });
    const name = typeof req.body?.name === 'string' ? req.body.name.trim() : '';
    const input = typeof req.body?.input === 'string' ? req.body.input.trim() : '';
    const wf = WORKFLOW_TEMPLATES.find(w => w.name === name);
    if (!wf) return res.status(400).json({ error: `unknown workflow: ${name}` });
    const prompt = wf.prompt + (input ? '\n\n' + input : '');
    try {
      const reply = await runTurn(session, prompt, {});
      await persistSession(session);
      res.json({ reply });
    } catch (e) {
      res.status(500).json({ error: String(e) });
    }
  });

  // ── Recurring prompt (/loop) ──────────────────────────────────────────
  app.get('/api/session/:id/loop', (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'no session' });
    res.json({
      loops: (session.schedules ?? [])
        .filter(s => s.status === 'active' && s.repeatMs)
        .map(s => ({ id: s.id, prompt: s.prompt, at: s.at, repeatMs: s.repeatMs, runs: s.runs ?? 0 })),
    });
  });
  app.post('/api/session/:id/loop', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'no session' });
    if (req.body?.stop === true) {
      let cancelled = 0;
      for (const s of session.schedules ?? []) {
        if (s.status === 'active' && s.repeatMs) { s.status = 'cancelled'; cancelled++; }
      }
      await persistSession(session);
      return res.json({ cancelled });
    }
    const prompt = typeof req.body?.prompt === 'string' ? req.body.prompt.trim() : '';
    const interval = typeof req.body?.interval === 'number' ? req.body.interval : 0;
    if (!prompt) return res.status(400).json({ error: 'prompt is required' });
    if (!Number.isFinite(interval) || interval < 1000) {
      return res.status(400).json({ error: 'interval must be at least 1000 ms' });
    }
    const loop: Schedule = {
      id: `loop-${Date.now()}`,
      prompt,
      at: new Date(Date.now() + interval).toISOString(),
      repeatMs: interval,
      status: 'active',
      runs: 0,
    };
    session.schedules = [...(session.schedules ?? []), loop];
    await persistSession(session);
    res.json({ id: loop.id, at: loop.at, interval });
  });

  // ── Fork / branch (/fork, /branch) ────────────────────────────────────
  app.post('/api/session/:id/fork', async (req, res) => {
    const parent = sessions.get(req.params.id);
    if (!parent) return res.status(404).json({ error: 'no session' });
    const upto = typeof req.body?.upto === 'number' ? req.body.upto : parent.messages.length;
    try {
      const id = await forkSession(parent, upto, 'fork');
      res.json({ id, messages: sessions.get(id)?.messages.length ?? 0 });
    } catch (e) {
      res.status(500).json({ error: String(e) });
    }
  });

  app.post('/api/session/:id/branch', async (req, res) => {
    const parent = sessions.get(req.params.id);
    if (!parent) return res.status(404).json({ error: 'no session' });
    // Branch = fork just before the last user turn, so the last prompt can be
    // sent again with a different approach.
    let upto = parent.messages.length;
    for (let i = parent.messages.length - 1; i >= 0; i--) {
      if (parent.messages[i]?.role === 'user') { upto = i; break; }
    }
    try {
      const id = await forkSession(parent, upto, 'branch');
      res.json({ id, messages: sessions.get(id)?.messages.length ?? 0 });
    } catch (e) {
      res.status(500).json({ error: String(e) });
    }
  });

  // ── Steering (/steer): inject into the running turn ───────────────────
  app.post('/api/session/:id/steer', (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'no session' });
    const prompt = typeof req.body?.prompt === 'string' ? req.body.prompt.trim() : '';
    if (!prompt) return res.status(400).json({ error: 'prompt is required' });
    session.steer = [...(session.steer ?? []), prompt];
    res.json({ steered: session.steer.length, running: inFlight.has(session.id) });
  });

  // ── Message queue (/queue) ────────────────────────────────────────────
  app.get('/api/session/:id/queue', (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'no session' });
    res.json({ queued: (session.queued ?? []).map(q => ({ message: q.message })) });
  });
  app.post('/api/session/:id/queue', (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'no session' });
    const message = typeof req.body?.message === 'string' ? req.body.message.trim() : '';
    if (!message) return res.status(400).json({ error: 'message is required' });
    session.queued = [...(session.queued ?? []), { message }];
    const depth = session.queued.length;
    // A queued message starts immediately when nothing is running.
    if (!inFlight.has(session.id) && !isSessionBusy(session.id)) {
      session.abortRequested = false;
      const next = session.queued.shift()!;
      void runTurn(session, next.message, next.target ?? {});
    }
    res.json({ queued: depth });
  });

  // ── Session recap (/recap): summarize without touching the convo ──────
  app.post('/api/session/:id/recap', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'no session' });
    if (session.messages.length === 0) return res.json({ summary: '' });
    const mode = MODES[session.mode] ?? MODES.standard;
    const model = session.lastRequest?.model ?? 'deepseek-flash';
    const messages = await withSystemPrompt(mode, model, session.cwd ?? WORKSPACE, [
      ...session.messages,
      {
        role: 'user',
        content:
          'Summarize this conversation so far: key decisions, open questions, and the next step. ' +
          'Keep it under 10 bullet points.',
      },
    ]);
    let summary = '';
    try {
      await bridge.queryModelStream(
        {
          messages: messages as Parameters<typeof bridge.queryModelStream>[0]['messages'],
          genParams: { sessionId: session.id },
        },
        d => { summary += d; },
      );
      res.json({ summary });
    } catch (e) {
      res.status(502).json({ error: String(e) });
    }
  });

  // ── Side question (/btw): answers without touching the conversation ────
  app.post('/api/session/:id/btw', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'no session' });
    const question = typeof req.body?.question === 'string' ? req.body.question.trim() : '';
    if (!question) return res.status(400).json({ error: 'question is required' });
    const mode = MODES[session.mode] ?? MODES.standard;
    const model = session.lastRequest?.model ?? 'deepseek-flash';
    const messages = await withSystemPrompt(mode, model, session.cwd ?? WORKSPACE, [
      ...session.messages,
      { role: 'user', content: question },
    ]);
    let answer = '';
    try {
      await bridge.queryModelStream(
        { messages: messages as Parameters<typeof bridge.queryModelStream>[0]['messages'], genParams: { sessionId: session.id } },
        d => { answer += d; },
      );
      res.json({ answer });
    } catch (e) {
      res.status(502).json({ error: String(e) });
    }
  });

  // ── Retry the last turn (/retry) ──────────────────────────────────────
  app.post('/api/session/:id/retry', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'no session' });
    const last = session.lastRequest;
    if (!last) return res.status(400).json({ error: 'nothing to retry' });
    // Drop the user turn being retried so the replay does not duplicate it.
    const tail = session.messages[session.messages.length - 1];
    if (tail && tail.role === 'user' && tail.content === last.message) session.messages.pop();
    try {
      const reply = await runTurn(session, last.message, last);
      await persistSession(session);
      res.json({ reply });
    } catch (e) {
      res.status(500).json({ error: String(e) });
    }
  });

  // ── Manual context compaction (/compact) ──────────────────────────────
  app.post('/api/session/:id/compact', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'no session' });
    const governed = govern(session.messages, session.lastPromptTokens ?? 0, governanceConfig());
    session.messages = governed.messages;
    session.lastMaintenance = { trigger: governed.trigger, savedTokens: governed.savedTokens };
    await persistSession(session);
    events.emit('agent:context', {
      sessionId: session.id, trigger: governed.trigger,
      savedTokens: governed.savedTokens, prefixChanged: governed.prefixChanged,
    });
    res.json({ trigger: governed.trigger, savedTokens: governed.savedTokens });
  });

  app.post('/api/session/:id/mode', (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    const action = typeof req.body?.action === 'string' ? req.body.action : 'cycle';
    if (action === 'yolo') {
      const swapped = toggleYolo(session.permissionMode ?? 'read-only', session.yoloRestore ?? null);
      session.permissionMode = swapped.mode;
      session.yoloRestore = swapped.restore;
      // planMode is deliberately untouched: YOLO inside a plan changes the
      // approval posture, not the plan itself.
    } else if (action === 'set' && typeof req.body?.mode === 'string') {
      const wanted = req.body.mode as PermissionMode;
      if (!MODE_CYCLE.includes(wanted)) return res.status(400).json({ error: `Unknown mode: ${wanted}` });
      // Plan is a flag: entering it keeps the approval mode at `ask`, exactly
      // like the Shift+Tab cycle (one state shape, two entry points).
      session.permissionMode = wanted === 'plan' ? 'ask' : wanted;
      session.planMode = wanted === 'plan';
      session.yoloRestore = null;
      if (wanted === 'plan') session.goal = null;
    } else {
      // Shift+Tab (Studio order): plan → read-only → ask → auto → YOLO → plan.
      // Entering plan lands on the ask posture; leaving plan lands on read-only.
      const mode = (session.permissionMode ?? 'read-only') as PermissionMode;
      if (session.planMode) {
        session.planMode = false;
        session.permissionMode = 'read-only';
      } else if (mode === 'read-only') {
        session.permissionMode = 'ask';
      } else if (mode === 'ask') {
        session.permissionMode = 'auto';
      } else if (mode === 'auto') {
        session.yoloRestore = 'auto';
        session.permissionMode = 'yolo';
      } else if (mode === 'yolo') {
        session.yoloRestore = null;
        session.planMode = true;
        session.permissionMode = 'ask';
      } else {
        session.permissionMode = 'auto';
      }
      if (session.planMode) session.goal = null;
    }
    persistSession(session);
    events.emit('session:mode', { sessionId: session.id, ...modeState(session) });
    res.json(modeState(session));
  });

  // ── Approval decisions (Phase 2 S1) ───────────────────────────────────

  app.post('/api/session/:id/decision', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });

    // A plan decision: the kernel owns plans, so this is a pure forward. Doing
    // it before the local gate keeps the two machines from both answering.
    const planAction = req.body?.action;
    if (typeof planAction === 'string') {
      const reason = typeof req.body?.reason === 'string' ? req.body.reason : undefined;
      try {
        const answer = await bridge.decidePlan(session.id, planAction, reason);
        events.emit('agent:decision', {
          sessionId: session.id, action: planAction,
          ...(reason ? { reason } : {}),
        });
        return res.json({ ...answer, mode: session.mode });
      } catch (e) {
        return res.status(502).json({ error: `kernel plan decision failed: ${String(e)}` });
      }
    }

    const pending = session.pendingApproval;
    if (!pending) return res.status(400).json({ error: 'No pending approval' });
    const approve = req.body?.approve === true;
    const reason = typeof req.body?.reason === 'string' ? req.body.reason : undefined;
    session.pendingApproval = null;
    // Release the kernel's barrier before running anything: if it kept the
    // session parked, the next step would be refused.
    void bridge.decideApproval(session.id, approve, reason).catch(e =>
      console.error(`kernel approval decision ${session.id}:`, e));
    events.emit('agent:decision', {
      sessionId: session.id, approve,
      ...(reason ? { reason } : {}),
    });
    if (!approve) {
      return res.json({ status: 'denied', mode: session.mode });
    }
    // ask 工具确认后批准 → 重放该工具结果（权限规则 ask 分支）
    const pendingCall = (session as { pendingToolCall?: ToolCallData | undefined }).pendingToolCall;
    if (pendingCall) {
      const output = await executeTool(pendingCall);
      (session as { pendingToolCall?: ToolCallData | undefined }).pendingToolCall = undefined;
      // The parked call already has a placeholder tool message; replace it so
      // the history keeps exactly one reply per tool_call_id.
      const last = session.messages[session.messages.length - 1];
      if (last && last.role === 'tool' && last.tool_call_id === pendingCall.id) {
        last.content = output;
      } else {
        session.messages.push({ role: 'tool', tool_call_id: pendingCall.id, content: output });
      }
      const reply = await runTurn(session, pending.message, pending);
      return res.json({ status: 'approved', tool: pendingCall.name, output, reply, messages: session.messages, mode: session.mode });
    }
    const reply = await runTurn(session, pending.message, pending);
    res.json({ status: 'approved', reply, messages: session.messages, mode: session.mode });
  });

  // ── Interrupt ─────────────────────────────────────────────────────────
  // The agent loop checks abortRequested between tool rounds.  Refuse when
  // idle: setting the flag there would abort the *next* turn instead.
  app.post('/api/session/:id/interrupt', (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    const busy = inFlight.has(session.id) || isSessionBusy(session.id);
    if (!busy) return res.json({ aborted: false });
    session.abortRequested = true;
    events.emit('agent:interrupt', { sessionId: session.id });
    res.json({ aborted: true });
  });

  // ── Human answers ─────────────────────────────────────────────────────
  // ask_user_question parks a question on the session; this is the way back.
  // Answering runs the next turn: the agent asked in order to continue.
  app.post('/api/session/:id/answer', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    const answer = typeof req.body?.answer === 'string' ? req.body.answer : '';
    if (!answer.trim()) return res.status(400).json({ error: 'Answer must be a non-empty string' });
    const pending = session.pendingQuestion;
    if (!pending) return res.status(400).json({ error: 'No question is pending' });
    session.pendingQuestion = null;
    events.emit('agent:answer', { sessionId: session.id, questionId: pending.id, answer });
    try {
      const reply = await withSessionLock(session.id, () => runTurn(session, answer, {}));
      await persistSession(session);
      return res.json({ status: 'answered', questionId: pending.id, reply, mode: session.mode });
    } catch (e) {
      return res.status(502).json({ error: `turn failed: ${String(e)}` });
    }
  });

  // ── Schedule driver ───────────────────────────────────────────────────
  //
  // A schedule record is only half the feature: something has to turn `at` into
  // a turn. The driver runs on a timer, fires due schedules by calling the same
  // `runStep` the HTTP route uses, and persists *before* spending so a crash
  // cannot double-fire.
  //
  // Catch-up rule: a schedule that came due while the process was down is fired
  // if it is younger than the grace window; older ones are marked `missed`.
  // Replaying an arbitrary backlog at boot would be a cost bomb, and silently
  // firing nothing would make the schedule look honoured when it was not.
  const scheduleTickMs = envInt('TRHA_SCHEDULE_TICK_MS', 5000, { allowZero: true });
  const scheduleGraceMs = envInt('TRHA_SCHEDULE_GRACE_MS', 5 * 60_000, { min: 1 });
  // Sessions with a turn in flight: used by interrupt_agent and by the driver
  // to avoid overlapping turns on one session.
  const inFlight = new Set<string>();
  const drivingSessions = new Set<string>();
  let subagentSeq = 0;
  let ticking = false;
  const maxSubagentDepth = envInt('TRHA_MAX_SUBAGENT_DEPTH', 2, { allowZero: true });

  const rootSessionOf = (session: SchedulerSession): SchedulerSession => {
    let cur = session;
    const seen = new Set<string>();
    while (cur.parentId && !seen.has(cur.id)) {
      seen.add(cur.id);
      const parent = sessions.get(cur.parentId);
      if (!parent) break;
      cur = parent;
    }
    return cur;
  };

  /** Wrap one turn so interrupt_agent and the driver see that it is running. */
  const runTurn = async (
    session: SchedulerSession,
    message: string,
    target: Parameters<typeof runStep>[2] = {},
    onDelta?: Parameters<typeof runStep>[3],
  ): Promise<string> => {
    inFlight.add(session.id);
    try {
      return await runStep(session, message, target, onDelta);
    } finally {
      inFlight.delete(session.id);
      // An abort that arrived too late for the loop's round check must not
      // leak into the next turn.
      session.abortRequested = false;
      // /queue: a message parked during this turn starts one now.
      const next = session.queued?.shift();
      if (next && !session.abortRequested) {
        setTimeout(() => { void runTurn(session, next.message, next.target ?? {}); }, 0);
      }
    }
  };

  /** Copy a session (optionally truncated) into a new child session. */
  const forkSession = async (
    parent: SchedulerSession, upto: number, label: string,
  ): Promise<string> => {
    const id = `session-${Date.now()}-${label}`;
    const child: SchedulerSession = {
      id,
      mode: parent.mode,
      messages: parent.messages.slice(0, Math.max(0, upto)).map(m => ({ ...m })),
      pendingApproval: null,
      createdAt: new Date(),
      parentId: parent.id,
      depth: parent.depth ?? 0,
      permissionMode: parent.permissionMode ?? 'read-only',
      planMode: parent.planMode ?? false,
      yoloRestore: parent.yoloRestore ?? null,
      ...(parent.cwd ? { cwd: parent.cwd } : {}),
    };
    sessions.set(id, child);
    await persistSession(child);
    void bridge.startKernelSession(id, child.mode).catch(e =>
      console.error(`kernel session create ${id}:`, e));
    events.emit('session:created', { sessionId: id, mode: child.mode });
    return id;
  };

  const spawnAgent = async (
    parent: SchedulerSession, task: string, name?: string, agentName?: string,
  ): Promise<{ id: string; reply: string }> => {
    const depth = (parent.depth ?? 0) + 1;
    if (depth > maxSubagentDepth) {
      throw new Error(`subagent depth limit reached (${maxSubagentDepth})`);
    }
    // A named agent definition supplies mode/model/effort/tools/instructions.
    const def = agentName
      ? (await loadAgentDefinitions(agentDirs(parent.cwd ?? WORKSPACE)))
          .find(d => d.name === agentName)
      : undefined;
    if (agentName && !def) throw new Error(`unknown agent: ${agentName}`);
    const slug = (agentName ?? name ?? 'sub').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 24) || 'sub';
    const id = `${parent.id}#${slug}-${++subagentSeq}`;
    const child: SchedulerSession = {
      id,
      mode: def?.mode && MODES[def.mode] ? def.mode : parent.mode,
      messages: [],
      pendingApproval: null,
      createdAt: new Date(),
      parentId: parent.id,
      depth,
    };
    sessions.set(id, child);
    await persistSession(child);
    events.emit('agent:spawn', { sessionId: parent.id, child: id, task: task.slice(0, 160) });
    try {
      // Reasonix's ResolveModelEffort order: subagent_efforts[profile] >
      // role_efforts[<profile>] > role_efforts["subagent"] > subagent_effort.
      const eff = def?.effort ?? subagentEfforts(name) ?? roleEffort(name)
        ?? roleEffort('subagent') ?? subagentEffort();
      const model = def?.model && def.model !== 'inherit' ? def.model : undefined;
      const reply = await runTurn(child, task, {
        ...(eff ? { genParams: { effort: eff } } : {}),
        ...(model ? { model } : {}),
        ...(def?.tools?.length ? { toolsAllow: def.tools } : {}),
        ...(def?.instructions ? { extraInstructions: def.instructions } : {}),
      });
      await persistSession(child);
      return { id, reply };
    } finally {
      events.emit('agent:exit', { sessionId: parent.id, child: id });
    }
  };

  const agentHooksFor = (session: SchedulerSession): AgentHooks => ({
    spawn: (task, name, agent) => spawnAgent(session, task, name, agent),
    list: () => [...sessions.values()].map(s2 => ({
      id: s2.id,
      ...(s2.parentId ? { parentId: s2.parentId } : {}),
      busy: inFlight.has(s2.id),
      messages: s2.messages.length,
      mode: s2.mode,
    })),
    send: async (id, text) => {
      const target = sessions.get(id);
      if (!target) return { delivered: false };
      target.messages.push({ role: 'user', content: text });
      events.emit('agent:message', { sessionId: id, role: 'user', content: text });
      // A busy agent just queues: its loop will pick the message up next round.
      if (inFlight.has(id) || isSessionBusy(id)) {
        await persistSession(target);
        return { delivered: true };
      }
      const reply = await withSessionLock(target.id, () => runTurn(target, text));
      await persistSession(target);
      return { delivered: true, reply };
    },
    interrupt: id => {
      const target = sessions.get(id);
      if (!target) return false;
      const wasBusy = inFlight.has(id);
      // The loop checks the flag between rounds and between tool calls; setting
      // it on an idle agent is harmless and keeps the tool honest.
      target.abortRequested = true;
      return wasBusy;
    },
    teamTasks: () => rootSessionOf(session).teamTasks ?? [],
    setTeamTasks: tasks => {
      rootSessionOf(session).teamTasks = tasks;
      void persistSession(rootSessionOf(session));
    },
  });

  const fireSchedule = async (session: SchedulerSession, s: Schedule): Promise<void> => {
    // Never step past a gate: the host owes a decision first.
    if (session.pendingApproval) return;
    if (drivingSessions.has(session.id)) return;
    drivingSessions.add(session.id);
    s.runs = (s.runs ?? 0) + 1;
    s.lastFiredAt = new Date().toISOString();
    if (s.repeatMs && s.repeatMs > 0) {
      s.at = new Date(Date.now() + s.repeatMs).toISOString();
    } else {
      s.status = 'fired';
    }
    // Durable before the spend: a crash mid-turn must not fire it twice.
    await persistSession(session);
    events.emit('agent:schedule', {
      sessionId: session.id, id: s.id, run: s.runs, prompt: s.prompt, status: 'firing',
    });
    try {
      const reply = await withSessionLock(session.id, () => runTurn(session, s.prompt, {}));
      events.emit('agent:schedule', {
        sessionId: session.id, id: s.id, run: s.runs, status: 'done', reply: reply.slice(0, 200),
      });
    } catch (e) {
      events.emit('agent:schedule', {
        sessionId: session.id, id: s.id, run: s.runs, status: 'error', error: String(e),
      });
      console.error(`schedule ${s.id} (${session.id}) failed:`, e);
    } finally {
      drivingSessions.delete(session.id);
      await persistSession(session);
    }
  };

  const approvalTimeoutMs = (): number =>
    envInt('TRHA_APPROVAL_TIMEOUT_MS', 300_000, { min: 1 });

  /** Auto-reject gates parked longer than the session's /ask-timeout. */
  const expireApprovals = async (): Promise<void> => {
    const now = Date.now();
    for (const session of sessions.values()) {
      if (!session.pendingApproval) continue;
      const at = session.pendingApprovalAt ? new Date(session.pendingApprovalAt).getTime() : now;
      const limit = session.askTimeoutMs ?? approvalTimeoutMs();
      if (now - at < limit) continue;
      session.pendingApproval = null;
      session.pendingApprovalAt = null;
      events.emit('agent:plan', {
        sessionId: session.id, status: 'rejected', message: 'approval timed out',
      });
      await persistSession(session);
    }
  };

  const tickSchedules = async (): Promise<void> => {
    if (ticking) return;
    ticking = true;
    try {
      await expireApprovals();
      const now = Date.now();
      for (const session of sessions.values()) {
        for (const s of session.schedules ?? []) {
          if (s.status !== 'active') continue;
          if (new Date(s.at).getTime() > now) continue;
          await fireSchedule(session, s);
        }
      }
    } catch (e) {
      console.error('schedule tick failed:', e);
    } finally {
      ticking = false;
    }
  };

  // Catch-up sweep at boot: too-old one-shots are recorded as missed.
  const sweepOverdue = (): void => {
    const now = Date.now();
    for (const session of sessions.values()) {
      let changed = false;
      for (const s of session.schedules ?? []) {
        if (s.status !== 'active' || s.repeatMs) continue;
        if (new Date(s.at).getTime() < now - scheduleGraceMs) {
          s.status = 'missed';
          changed = true;
        }
      }
      if (changed) void persistSession(session);
    }
  };
  if (sessions.size > 0) sweepOverdue();
  let scheduleTimer: NodeJS.Timeout | undefined;
  if (scheduleTickMs > 0) {
    scheduleTimer = setInterval(() => { void tickSchedules(); }, scheduleTickMs);
    // Do not keep the process (or a test runner) alive just for the timer.
    scheduleTimer.unref?.();
  }

  /** Stop background work. Without this a "closed" scheduler keeps firing. */
  const stop = (): void => {
    if (scheduleTimer) clearInterval(scheduleTimer);
    scheduleTimer = undefined;
  };

  // ── Multi-step plans (kernel-owned) ───────────────────────────────────
  //
  // The scheduler keeps no copy of the plan: the kernel holds the steps, the
  // phase and the barrier, and persists all of it. These three routes are thin
  // forwards so the shell has one door.

  app.post('/api/session/:id/plan', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    try {
      const answer = await bridge.submitPlan(session.id, req.body as Record<string, unknown>);
      events.emit('agent:plan', { sessionId: session.id, ...answer });
      return res.json({ ...answer, mode: session.mode });
    } catch (e) {
      return res.status(502).json({ error: `kernel plan submit failed: ${String(e)}` });
    }
  });

  app.get('/api/session/:id/plan', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    try {
      const answer = await bridge.getPlan(session.id);
      return res.json({ ...answer, mode: session.mode });
    } catch (e) {
      return res.status(502).json({ error: `kernel plan read failed: ${String(e)}` });
    }
  });

  app.post('/api/session/:id/step-result', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    const { stepId, ok, output } = req.body as { stepId?: string; ok?: boolean; output?: unknown };
    if (typeof stepId !== 'string' || typeof ok !== 'boolean') {
      return res.status(400).json({ error: 'Expected stepId and ok' });
    }
    try {
      const answer = await bridge.reportStep(session.id, stepId, ok, output);
      // The host reported a step it ran: keep its own transcript in step.
      session.messages.push({
        role: 'assistant',
        content: `[plan] ${stepId} ${ok ? 'done' : 'failed'}`,
      });
      persistSession(session);
      return res.json({ ...answer, mode: session.mode });
    } catch (e) {
      return res.status(502).json({ error: `kernel step report failed: ${String(e)}` });
    }
  });

  // ── SSE event stream ──────────────────────────────────────────────────

  app.get('/api/events/:sessionId', (req, res) => {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    });

    const sessionId = req.params.sessionId;
    const handler = (data: unknown) => {
      // only forward events belonging to this session
      const payload = data as { sessionId?: string };
      if (payload?.sessionId && payload.sessionId !== sessionId) return;
      res.write(`data: ${JSON.stringify(data)}\n\n`);
    };

    // P-11: one registry, used for both subscribe and unsubscribe.
    for (const name of SSE_EVENTS) events.on(name, handler);
    req.on('close', () => {
      for (const name of SSE_EVENTS) events.off(name, handler);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // OpenAI-compatible API  (/v1/chat/completions, /v1/models)
  // ══════════════════════════════════════════════════════════════════════

  // GET /v1/models — list available models
  app.get('/v1/models', (_req, res) => {
    res.json({
      object: 'list',
      data: models.map(m => ({
        id: m.name,
        object: 'model',
        created: Math.floor(Date.now() / 1000),
        owned_by: 'trha',
        context_size: m.contextSize,
      })),
    });
  });

  // POST /v1/chat/completions — OpenAI chat completions
  app.post('/v1/chat/completions', async (req, res) => {
    const { model, messages, stream } = req.body;

    if (!messages || !Array.isArray(messages) || messages.length === 0) {
      return res.status(400).json({ error: { message: 'messages is required', type: 'invalid_request_error' } });
    }

    const modelInfo = models.find(m => m.name === model) || models[0];
    if (!modelInfo) {
      return res.status(400).json({ error: { message: `model not found: ${String(model)}`, type: 'invalid_request_error' } });
    }
    const requestId = `chatcmpl-${Date.now()}`;

    // Convert messages to bridge format
    const bridgeMessages: [string, string][] = messages.map((m: any) => [m.role, m.content]);

    // Stream mode
    if (stream) {
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      });

      try {
        let first = true;
        // Real increments: the kernel streams, we forward them as they arrive.
        await streamReply(bridgeMessages, text => {
          const chunk = {
            id: requestId,
            object: 'chat.completion.chunk',
            created: Math.floor(Date.now() / 1000),
            model: modelInfo.name,
            choices: [{
              index: 0,
              delta: first ? { role: 'assistant', content: text } : { content: text },
              finish_reason: null,
            }],
          };
          first = false;
          res.write(`data: ${JSON.stringify(chunk)}\n\n`);
        });

        // Final chunk
        res.write(`data: ${JSON.stringify({
          id: requestId,
          object: 'chat.completion.chunk',
          created: Math.floor(Date.now() / 1000),
          model: modelInfo.name,
          choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
        })}\n\n`);
        res.write('data: [DONE]\n\n');
      } catch {
        res.write(`data: ${JSON.stringify({ error: { message: 'Bridge error', type: 'server_error' } })}\n\n`);
      }
      res.end();
      return;
    }

    // Non-stream mode
    try {
      const response = await bridge.queryModel({ messages: bridgeMessages });
      const fullText = response.reply;

      res.json({
        id: requestId,
        object: 'chat.completion',
        created: Math.floor(Date.now() / 1000),
        model: modelInfo.name,
        choices: [{
          index: 0,
          message: { role: 'assistant', content: fullText },
          finish_reason: 'stop',
        }],
        usage: {
          prompt_tokens: messages.reduce((sum: number, m: any) => sum + (m.content?.length || 0) / 4, 0),
          completion_tokens: fullText.length / 4,
          total_tokens: (messages.reduce((sum: number, m: any) => sum + (m.content?.length || 0) / 4, 0) + fullText.length / 4),
        },
      });
    } catch {
      // Fallback: echo
      const lastMsg = messages[messages.length - 1];
      const reply = `[trha] ${lastMsg.content}`;
      res.json({
        id: requestId,
        object: 'chat.completion',
        created: Math.floor(Date.now() / 1000),
        model: modelInfo.name,
        choices: [{
          index: 0,
          message: { role: 'assistant', content: reply },
          finish_reason: 'stop',
        }],
        usage: { prompt_tokens: 0, completion_tokens: reply.length / 4, total_tokens: reply.length / 4 },
      });
    }
  });

  // ══════════════════════════════════════════════════════════════════════
  // Anthropic-compatible API  (/v1/messages)
  // ══════════════════════════════════════════════════════════════════════

  // POST /v1/messages — Anthropic messages API
  app.post('/v1/messages', async (req, res) => {
    const { model, messages, stream, system } = req.body;

    if (!messages || !Array.isArray(messages) || messages.length === 0) {
      return res.status(400).json({
        type: 'error',
        error: { type: 'invalid_request_error', message: 'messages is required' },
      });
    }

    const modelInfo = models.find(m => m.name === model) || models[0];
    if (!modelInfo) {
      return res.status(400).json({ error: { message: `model not found: ${String(model)}`, type: 'invalid_request_error' } });
    }
    const requestId = `msg-${Date.now()}`;

    // Convert Anthropic messages to bridge format
    const bridgeMessages: [string, string][] = [];
    if (system) bridgeMessages.push(['system', system]);
    for (const m of messages) {
      if (m.content && typeof m.content === 'string') {
        bridgeMessages.push([m.role, m.content]);
      } else if (Array.isArray(m.content)) {
        // Handle content blocks (text only for now)
        const text = m.content.filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n');
        if (text) bridgeMessages.push([m.role, text]);
      }
    }

    // Stream mode
    if (stream) {
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      });

      // message_start
      res.write(`event: message_start\ndata: ${JSON.stringify({
        type: 'message_start',
        message: {
          id: requestId,
          type: 'message',
          role: 'assistant',
          content: [],
          model: modelInfo.name,
          stop_reason: null,
          stop_sequence: null,
          usage: { input_tokens: 0, output_tokens: 0 },
        },
      })}\n\n`);

      // content_block_start
      res.write(`event: content_block_start\ndata: ${JSON.stringify({
        type: 'content_block_start',
        index: 0,
        content_block: { type: 'text', text: '' },
      })}\n\n`);

      try {
        await streamReply(bridgeMessages, text => {
          res.write(`event: content_block_delta\ndata: ${JSON.stringify({
            type: 'content_block_delta',
            index: 0,
            delta: { type: 'text_delta', text },
          })}\n\n`);
        });
      } catch {
        res.write(`event: content_block_delta\ndata: ${JSON.stringify({
          type: 'content_block_delta',
          index: 0,
          delta: { type: 'text_delta', text: '[trha] Bridge error' },
        })}\n\n`);
      }

      // content_block_stop
      res.write(`event: content_block_stop\ndata: ${JSON.stringify({
        type: 'content_block_stop',
        index: 0,
      })}\n\n`);

      // message_delta
      res.write(`event: message_delta\ndata: ${JSON.stringify({
        type: 'message_delta',
        delta: { stop_reason: 'end_turn', stop_sequence: null },
        usage: { output_tokens: 0 },
      })}\n\n`);

      // message_stop
      res.write(`event: message_stop\ndata: ${JSON.stringify({ type: 'message_stop' })}\n\n`);
      res.end();
      return;
    }

    // Non-stream mode
    try {
      const response = await bridge.queryModel({ messages: bridgeMessages });
      const fullText = response.reply;

      res.json({
        id: requestId,
        type: 'message',
        role: 'assistant',
        content: [{ type: 'text', text: fullText }],
        model: modelInfo.name,
        stop_reason: 'end_turn',
        stop_sequence: null,
        usage: {
          input_tokens: bridgeMessages.reduce((sum, m) => sum + Math.ceil(m[1].length / 4), 0),
          output_tokens: Math.ceil(fullText.length / 4),
        },
      });
    } catch {
      const lastMsg = messages[messages.length - 1];
      const reply = `[trha] ${typeof lastMsg.content === 'string' ? lastMsg.content : 'error'}`;
      res.json({
        id: requestId,
        type: 'message',
        role: 'assistant',
        content: [{ type: 'text', text: reply }],
        model: modelInfo.name,
        stop_reason: 'end_turn',
        stop_sequence: null,
        usage: { input_tokens: 0, output_tokens: Math.ceil(reply.length / 4) },
      });
    }
  });

  // ══════════════════════════════════════════════════════════════════════
  // OpenAI Responses API  (/v1/responses)
  // ══════════════════════════════════════════════════════════════════════

  // POST /v1/responses — OpenAI Responses API (newer protocol)
  app.post('/v1/responses', async (req, res) => {
    const { model, input, stream, instructions } = req.body;

    if (!input) {
      return res.status(400).json({ error: { message: 'input is required', type: 'invalid_request_error' } });
    }

    const modelInfo = models.find(m => m.name === model) || models[0];
    if (!modelInfo) {
      return res.status(400).json({ error: { message: `model not found: ${String(model)}`, type: 'invalid_request_error' } });
    }
    const responseId = `resp-${Date.now()}`;

    // Normalize input to messages
    const bridgeMessages: [string, string][] = [];
    if (instructions) bridgeMessages.push(['system', instructions]);

    if (typeof input === 'string') {
      bridgeMessages.push(['user', input]);
    } else if (Array.isArray(input)) {
      for (const item of input) {
        if (item.role && item.content) {
          bridgeMessages.push([item.role, typeof item.content === 'string' ? item.content : JSON.stringify(item.content)]);
        } else if (item.type === 'message' && item.content) {
          const text = Array.isArray(item.content)
            ? item.content.filter((c: any) => c.type === 'input_text').map((c: any) => c.text).join('\n')
            : item.content;
          bridgeMessages.push([item.role || 'user', text]);
        }
      }
    }

    // Stream mode
    if (stream) {
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      });

      // response.created
      res.write(`event: response.created\ndata: ${JSON.stringify({
        type: 'response.created',
        response: {
          id: responseId,
          object: 'response',
          created_at: Math.floor(Date.now() / 1000),
          model: modelInfo.name,
          output: [],
          status: 'in_progress',
        },
      })}\n\n`);

      // response.in_progress
      res.write(`event: response.in_progress\ndata: ${JSON.stringify({
        type: 'response.in_progress',
        response: {
          id: responseId,
          object: 'response',
          status: 'in_progress',
        },
      })}\n\n`);

      // output_item.added (message)
      const outputIndex = 0;
      res.write(`event: response.output_item.added\ndata: ${JSON.stringify({
        type: 'response.output_item.added',
        output_index: outputIndex,
        item: {
          type: 'message',
          id: `msg-${Date.now()}`,
          role: 'assistant',
          status: 'in_progress',
          content: [],
        },
      })}\n\n`);

      // content_part.added
      res.write(`event: response.content_part.added\ndata: ${JSON.stringify({
        type: 'response.content_part.added',
        output_index: outputIndex,
        content_index: 0,
        part: { type: 'output_text', text: '', annotations: [] },
      })}\n\n`);

      try {
        await streamReply(bridgeMessages, text => {
          res.write(`event: response.output_text.delta\ndata: ${JSON.stringify({
            type: 'response.output_text.delta',
            output_index: outputIndex,
            content_index: 0,
            delta: text,
          })}\n\n`);
        });
      } catch {
        res.write(`event: response.output_text.delta\ndata: ${JSON.stringify({
          type: 'response.output_text.delta',
          output_index: outputIndex,
          content_index: 0,
          delta: '[trha] Bridge error',
        })}\n\n`);
      }

      // output_text.done
      res.write(`event: response.output_text.done\ndata: ${JSON.stringify({
        type: 'response.output_text.done',
        output_index: outputIndex,
        content_index: 0,
        text: '',
      })}\n\n`);

      // content_part.done
      res.write(`event: response.content_part.done\ndata: ${JSON.stringify({
        type: 'response.content_part.done',
        output_index: outputIndex,
        content_index: 0,
        part: { type: 'output_text', text: '', annotations: [] },
      })}\n\n`);

      // output_item.done
      res.write(`event: response.output_item.done\ndata: ${JSON.stringify({
        type: 'response.output_item.done',
        output_index: outputIndex,
        item: {
          type: 'message',
          id: `msg-${Date.now()}`,
          role: 'assistant',
          status: 'completed',
          content: [],
        },
      })}\n\n`);

      // response.completed
      res.write(`event: response.completed\ndata: ${JSON.stringify({
        type: 'response.completed',
        response: {
          id: responseId,
          object: 'response',
          created_at: Math.floor(Date.now() / 1000),
          model: modelInfo.name,
          output: [],
          status: 'completed',
          usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0 },
        },
      })}\n\n`);
      res.end();
      return;
    }

    // Non-stream mode
    try {
      const response = await bridge.queryModel({ messages: bridgeMessages });
      const fullText = response.reply;

      res.json({
        id: responseId,
        object: 'response',
        created_at: Math.floor(Date.now() / 1000),
        model: modelInfo.name,
        output: [{
          type: 'message',
          id: `msg-${Date.now()}`,
          role: 'assistant',
          status: 'completed',
          content: [{ type: 'output_text', text: fullText, annotations: [] }],
        }],
        status: 'completed',
        usage: {
          input_tokens: bridgeMessages.reduce((sum, m) => sum + Math.ceil(m[1].length / 4), 0),
          output_tokens: Math.ceil(fullText.length / 4),
          total_tokens: bridgeMessages.reduce((sum, m) => sum + Math.ceil(m[1].length / 4), 0) + Math.ceil(fullText.length / 4),
        },
      });
    } catch {
      const inputText = typeof input === 'string' ? input : JSON.stringify(input);
      const reply = `[trha] ${inputText.slice(0, 100)}`;
      res.json({
        id: responseId,
        object: 'response',
        created_at: Math.floor(Date.now() / 1000),
        model: modelInfo.name,
        output: [{
          type: 'message',
          id: `msg-${Date.now()}`,
          role: 'assistant',
          status: 'completed',
          content: [{ type: 'output_text', text: reply, annotations: [] }],
        }],
        status: 'completed',
        usage: { input_tokens: 0, output_tokens: Math.ceil(reply.length / 4), total_tokens: Math.ceil(reply.length / 4) },
      });
    }
  });

  return { app, config, stop };
}

// Host-lease handshake (Electron host architecture):
//  * stdout carries exactly one line: versioned JSON handshake
//    { "v": 1, "name": "trha-scheduler", "port": N } -- hosts that do not
//    recognise the version refuse to start the child.
//  * all operational logs go to stderr.
//  * when TRHA_LEASE_STDIN=1, stdin is a lease: the host closing it (normal
//    exit or crash of the parent) makes the scheduler drain and exit.
export function startServer(config: ServerConfig = defaultServerConfig) {
  // A non-loopback listener with the default token is an unauthenticated admin
  // API on the network. Refusing here is the difference between "exposed on
  // purpose, with a secret" and "exposed by accident".
  const host = config.host ?? '127.0.0.1';
  if (host !== '127.0.0.1' && host !== 'localhost' && config.token === 'dev-token') {
    throw new Error(
      'refusing to listen on a non-loopback address with the default token: '
      + 'set TRHA_TOKEN (or pass --token) to a real secret, or prefer an SSH tunnel'
    );
  }
  const { app } = createServer(config);
  const tls = resolveTls();
  return new Promise<void>((resolve) => {
    const onListen = () => {
      const scheme = tls ? 'https' : 'http';
      const handshake = config.socketPath
        ? { v: 1, name: 'trha-scheduler', port: 0, socket: config.socketPath }
        : { v: 1, name: 'trha-scheduler', port: config.port, scheme };
      process.stdout.write(JSON.stringify(handshake) + '\n');
      if (config.socketPath) {
        console.error(`Scheduler listening on ${config.socketPath}`);
      } else {
        console.error(`Scheduler listening on ${scheme}://${config.host ?? '127.0.0.1'}:${config.port}`);
      }
      console.error(`Modes: ${Object.keys(MODES).join(', ')}`);
      console.error(`Tools: ${catalogToolDefs().length} registered`);
      resolve();
    };
    if (config.socketPath) {
      // remove a stale socket file from a previous run, then listen on UDS
      try { rmSync(config.socketPath); } catch { /* ignore */ }
      app.listen(config.socketPath, onListen);
      process.on('exit', () => {
        try { rmSync(config.socketPath ?? ''); } catch { /* ignore */ }
      });
    } else if (tls) {
      createHttpsServer(tls, app).listen(config.port, config.host ?? '127.0.0.1', onListen);
    } else {
      app.listen(config.port, config.host ?? '127.0.0.1', onListen);
    }
  });
}

if (process.env.TRHA_LEASE_STDIN === '1') {
  process.stdin.resume();
  process.stdin.on('end', () => {
    // lease dropped: parent gone (crash or exit) -- drain and leave
    process.exit(0);
  });
  process.stdin.on('close', () => process.exit(0));
}
