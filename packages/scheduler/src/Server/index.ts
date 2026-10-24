// Scheduler HTTP Server
// Exposes the scheduler as an HTTP API for the Desktop app
// Mode system ported from deepseek-harness standard/ptc/minimal/cordis presets

import express from 'express';
import cors from 'cors';
import { HaskellBridge } from '../Bridge/Haskell.js';
import type { BridgeToolSpec, ToolCallData } from '../Bridge/Haskell.js';
import { canonicalToolName, toToolSpecs } from './toolCatalog.js';
import { confineWritePath, limitOutput } from './toolGuard.js';
import { decidePermission, setPermissionRules, compileRules, getPermissionRules } from '../Permission/permissionRules.js';
import { EventEmitter } from '../Utils/EventEmitter.js';
import { Plugin, PluginManager } from '../Plugins/Plugin.js';
import { loadPluginsFrom } from '../Plugins/loader.js';
import { fileURLToPath } from 'node:url';
import { readFileSync, rmSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { loadPin, loadSessionsSync, removeSessionFile, savePin, saveSession } from './stateStore.js';
import { govern, DEFAULT_GOVERNANCE, type GovernanceConfig } from './contextGovernor.js';
import { envCap, envInt } from './env.js';
import { isExtraTool, runExtraTool, type ExtraHost, type Terminal } from './extraTools.js';
import {
  isStandardTool, runStandardTool, startJob,
  type AgentHooks, type Goal, type PendingQuestion, type Schedule, type TeamTask,
  type Todo, type JobRecord,
} from './standardTools.js';
import { startPluginWatcher } from '../Plugins/watcher.js';
import { mkdir, readdir, readFile, writeFile, appendFile } from 'node:fs/promises';
import { exec } from 'node:child_process';
import { promisify } from 'node:util';
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
  port: 3456,
  host: '127.0.0.1',
  token: process.env.TRHA_TOKEN || 'dev-token',
  haskellHost: 'localhost',
  haskellPort: 8080,
};

// ── Tool definitions ──────────────────────────────────────────────────────

interface ToolDef {
  name: string;
  description: string;
  enabled: boolean;
  schema: Record<string, string>;
}

const ALL_TOOLS: ToolDef[] = [
  // Shell & Filesystem
  { name: 'bash',              description: 'Execute shell commands in a bash shell',            enabled: true, schema: { command: 'string' } },
  { name: 'read',              description: 'Read a file (with optional offset/limit)',          enabled: true, schema: { path: 'string', offset: 'number?', limit: 'number?' } },
  { name: 'write',             description: 'Write a file (create or overwrite)',                enabled: true, schema: { path: 'string', content: 'string' } },
  { name: 'edit',              description: 'Edit a file with exact string find/replace',        enabled: true, schema: { file_path: 'string', old_string: 'string', new_string: 'string' } },
  { name: 'grep',              description: 'Search file contents with ripgrep regex',           enabled: true, schema: { pattern: 'string', path: 'string?', include: 'string?' } },
  { name: 'glob',              description: 'Find files by glob pattern',                        enabled: true, schema: { pattern: 'string', path: 'string?' } },
  { name: 'web_search',        description: 'Search the web (1-4 queries)',                      enabled: true, schema: { queries: 'string[]' } },
  { name: 'web_fetch',         description: 'Fetch a URL and return text/markdown',              enabled: true, schema: { url: 'string', prompt: 'string?' } },
  { name: 'describe_image',    description: 'OCR/analyze an image file or URL',                  enabled: true, schema: { image: 'string', prompt: 'string' } },

  // Agent & Delegation
  { name: 'subagent',          description: 'Delegate task to a background sub-agent',           enabled: true, schema: { description: 'string', prompt: 'string' } },
  { name: 'subagent_fork',     description: 'Fork current conversation to a sub-agent',          enabled: true, schema: { description: 'string', prompt: 'string' } },
  { name: 'workflow',          description: 'Run a multi-step workflow across sub-agents',        enabled: true, schema: { script: 'string', meta: 'object' } },
  { name: 'ralph',             description: 'Fresh-agent iterative loop toward an objective',     enabled: true, schema: { objective: 'string', maxRounds: 'number?' } },
  { name: 'ask_user',          description: 'Ask the user a question',                            enabled: true, schema: { questions: 'object[]' } },

  // Session & State
  { name: 'todo',              description: 'Write/update structured task list',                  enabled: true, schema: { todos: 'object[]' } },
  { name: 'plan',              description: 'Enter plan mode (non-mutating exploration)',         enabled: true, schema: { plan: 'string' } },
  { name: 'checkpoint',        description: 'Create a unified workspace/session checkpoint',      enabled: true, schema: { note: 'string?' } },
  { name: 'memory_remember',   description: 'Persist a fact to cross-session memory vault',       enabled: true, schema: { content: 'string', tags: 'string[]?' } },
  { name: 'memory_recall',     description: 'Search cross-session memory vault',                  enabled: true, schema: { query: 'string', limit: 'number?' } },
  { name: 'memory_forget',     description: 'Delete entries from memory vault',                   enabled: true, schema: { id: 'string?', tag: 'string?' } },

  // PTC Mode
  { name: 'run_code',          description: 'PTC: execute model-authored program against tools',  enabled: true, schema: { code: 'string', description: 'string' } },

  // Skills & Plugins
  { name: 'skill',             description: 'Load and execute a skill by name',                   enabled: true, schema: { name: 'string' } },

  // Remote & SSH
  { name: 'remote_host_add',   description: 'Register a remote compute host',                    enabled: true, schema: { host: 'string', alias: 'string?' } },
  { name: 'remote_exec',       description: 'Execute a short command on a remote host',           enabled: true, schema: { host: 'string', command: 'string' } },
  { name: 'remote_run',        description: 'Submit a background job to a remote host',           enabled: true, schema: { host: 'string', script: 'string', title: 'string?' } },
  { name: 'remote_status',     description: 'Check remote job status',                            enabled: true, schema: { job: 'string?' } },
  { name: 'remote_pull',       description: 'Pull remote job output to local',                    enabled: true, schema: { job: 'string' } },
  { name: 'remote_cancel',     description: 'Cancel a remote job',                                enabled: true, schema: { job: 'string' } },
  { name: 'remote_logs',       description: 'View remote job logs',                               enabled: true, schema: { job: 'string', stream: 'string?' } },
  { name: 'ssh_exec',          description: 'Execute command on configured SSH host',             enabled: true, schema: { alias: 'string', command: 'string' } },
  { name: 'ssh_download',      description: 'Download file from SSH host',                        enabled: true, schema: { alias: 'string', remotePath: 'string', localPath: 'string' } },
  { name: 'ssh_upload',        description: 'Upload file to SSH host',                            enabled: true, schema: { alias: 'string', localPath: 'string', remotePath: 'string' } },
  { name: 'ssh_tunnel',        description: 'Manage local port-forward tunnels to SSH host',      enabled: true, schema: { action: 'string', alias: 'string?', remotePort: 'number?' } },
  { name: 'ssh_cluster',       description: 'Run command concurrently across SSH hosts',          enabled: true, schema: { command: 'string', aliases: 'string[]?' } },

  // Browser & Pilot
  { name: 'pilot_open',        description: 'Open URL in controlled browser',                     enabled: true, schema: { url: 'string' } },
  { name: 'pilot_click',       description: 'Click element in browser',                           enabled: true, schema: { ref: 'number?', selector: 'string?' } },
  { name: 'pilot_type',        description: 'Type text into browser input',                       enabled: true, schema: { text: 'string', ref: 'number?', selector: 'string?' } },
  { name: 'pilot_snapshot',    description: 'Read browser page as text snapshot',                  enabled: true, schema: {} },
  { name: 'pilot_screenshot',  description: 'Capture browser page screenshot',                    enabled: true, schema: { path: 'string?' } },

  // GitHub
  { name: 'github_repo',       description: 'Get GitHub repository metadata',                     enabled: true, schema: { owner: 'string', repo: 'string' } },
  { name: 'github_issues',     description: 'List GitHub issues',                                 enabled: true, schema: { owner: 'string', repo: 'string', state: 'string?' } },
  { name: 'github_prs',        description: 'List GitHub pull requests',                          enabled: true, schema: { owner: 'string', repo: 'string', state: 'string?' } },
  { name: 'github_create_issue', description: 'Create a GitHub issue',                            enabled: true, schema: { owner: 'string', repo: 'string', title: 'string', body: 'string?' } },
  { name: 'github_create_pr',  description: 'Create a GitHub pull request',                       enabled: true, schema: { owner: 'string', repo: 'string', title: 'string', head: 'string', base: 'string' } },
  { name: 'github_search',     description: 'Search GitHub repositories/code/issues',             enabled: true, schema: { query: 'string', type: 'string?' } },

  // Research & Deep Read
  { name: 'deepread',          description: 'Deep-read books/articles/PDFs with analysis',        enabled: true, schema: { path: 'string?', url: 'string?', depth: 'string?' } },

  // Compressor (context management)
  { name: 'compressor_retrieve', description: 'Retrieve compressed conversation text',            enabled: true, schema: { locator: 'string' } },

  // Artifacts (versioned outputs)
  { name: 'artifact_save',     description: 'Save analysis/chart/data as versioned artifact',     enabled: true, schema: { name: 'string', sources: 'string[]' } },
  { name: 'artifact_list',     description: 'List all versioned artifacts',                       enabled: true, schema: {} },
  { name: 'artifact_show',     description: 'Show artifact metadata and provenance',              enabled: true, schema: { name: 'string' } },

  // Background Jobs
  { name: 'job_output',        description: 'Read background job output',                         enabled: true, schema: { job_id: 'string', wait: 'boolean?' } },
  { name: 'job_kill',          description: 'Cancel a running background job',                    enabled: true, schema: { job_id: 'string' } },

  // Double-check Discipline
  { name: 'doublecheck_spec',  description: 'Record grilled requirements spec',                   enabled: true, schema: { goal: 'string', scope: 'string', acceptanceCriteria: 'string' } },
  { name: 'doublecheck_report', description: 'Generate delivery proof report',                    enabled: true, schema: { filePath: 'string?' } },

  // Research Loop
  { name: 'research_init',     description: 'Initialize research project',                        enabled: true, schema: { title: 'string?', domain: 'string?', question: 'string?' } },
  { name: 'research_hypothesis', description: 'Register a research hypothesis',                   enabled: true, schema: { text: 'string', question: 'string?' } },
  { name: 'research_experiment', description: 'Register an experiment',                           enabled: true, schema: { title: 'string', objective: 'string', plan: 'string[]' } },
  { name: 'research_findings', description: 'Record experiment findings',                         enabled: true, schema: { experiment: 'string', finding: 'string', conclusion: 'string?' } },

  // Logic Verification
  { name: 'logicprobe_verify', description: 'Run executable state-machine verification',          enabled: true, schema: { model: 'object' } },
];

// ── Tool lifecycle event (Phase 2 S2) ─────────────────────────────────
// Pushed to /api/events/:sessionId as `tool:update`; mirrors CLI ToolEvent.

interface ToolEvent {
  name: string;
  args?: string[];
  status: 'running' | 'succeeded' | 'failed';
  error?: string;
  durationMs?: number;
}

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

interface SchedulerSession {
  id: string;
  mode: string;
  messages: SessionMessage[];
  pendingApproval: { message: string } | null;
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
  /** Cards shown to the user; never part of the model's history. */
  presentations?: Array<{ card: string; at: string }>;
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

/** Session messages as the model should see them: a system message first, then the rest. */
function withSystemPrompt(
  mode: ModeConfig, model: string, cwd: string,
  messages: Array<{ role: string; content: string }>,
): Array<Record<string, unknown>> {
  const system = systemMessageFor(mode, model, cwd);
  // Computed per request instead of stored: a stored system message would be
  // rewritten by maintenance and would pollute the transcript the shell shows.
  return system
    ? [{ role: 'system', content: system }, ...messages]
    : [...messages];
}

const MODES: Record<string, ModeConfig> & { standard: ModeConfig } = {
  standard: {
    name: 'standard',
    description: 'Full coding agent with all tools and capabilities',
    tools: ALL_TOOLS.filter(t => t.name !== 'run_code').map(t => t.name),
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
    tools: ALL_TOOLS.filter(t => !['workflow', 'todo', 'plan'].includes(t.name)).map(t => t.name),
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
    tools: ['bash', 'read', 'write', 'grep', 'glob', 'edit', 'web_fetch', 'describe_image', 'ask_user'],
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
  const bridge = new HaskellBridge({ host: config.haskellHost, port: config.haskellPort });

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

  app.use(cors());
  app.use(express.json());

  // Authentication: Bearer token by default; the /studio pages are served
  // from this same loopback listener, so same-origin requests (browser sends
  // an Origin header equal to this listener) bypass the token -- mirroring
  // the Reasonix loopback gate.  Cross-origin browsers are always refused;
  // token-less non-browser callers keep working through the Bearer check.
  app.use((req, res, next) => {
    if (req.path === '/health' || req.path.startsWith('/v1/') || req.path.startsWith('/studio')) return next();
    const origin = req.headers.origin;
    const isRead = req.method === 'GET' || req.method === 'HEAD' || req.method === 'OPTIONS';
    const loopbackOnly = (config.host ?? '127.0.0.1') === '127.0.0.1';
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

  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', version: '0.1.0', modes: Object.keys(MODES) });
  });

  // ── /studio pages + version surface (loopback host; one routing rule:
  // /studio* -> static page assets, everything else stays on the API) ──
  const studioDir = config.studioDir
    ?? path.join(__dirname, '..', '..', 'studio-public');
  app.use('/studio', (req, res, next) => {
    if ((req.method === 'GET' || req.method === 'HEAD')
        && cookieValue(req.headers.cookie, SESSION_COOKIE) === undefined) {
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
      res.json(ALL_TOOLS.filter(t => modeTools.includes(t.name)));
    } else {
      res.json(ALL_TOOLS);
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

  async function forwardToKernel(
    res: import('express').Response,
    method: 'GET' | 'POST',
    path: string,
    body?: unknown,
  ): Promise<void> {
    try {
      const r = await fetch(`${kernelBase()}${path}`, {
        method,
        headers: { 'Content-Type': 'application/json' },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
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
  app.get('/api/sandbox/write-roots', (_req, res) => {
    res.json({ roots: extraWriteRoots });
  });
  app.put('/api/sandbox/write-roots', (req, res) => {
    const roots = Array.isArray(req.body?.roots) ? req.body.roots.filter((x: unknown) => typeof x === 'string') : [];
    extraWriteRoots = roots;
    res.json({ roots: extraWriteRoots });
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
    const sessionId = `session-${Date.now()}`;
    const created = { id: sessionId, mode, messages: [] as SessionMessage[], pendingApproval: null, createdAt: new Date() };
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

  // ── Agent step ────────────────────────────────────────────────────────

  // Run one full agent step and return the (aggregated) reply text.
  // Shared by the plain /api/agent/step path and by the approval gate
  // after the host approves a pending plan.
  // ── Tool loop (Phase 3 K5) ─────────────────────────────────────────────
  // Host-side tool executions: read-only file access for now.  The kernel
  // emits assistant tool_calls; we execute them and feed results back as
  // tool messages until the model answers without tool calls.
  // Host-side tools live under the orchestration workspace so file mutations
  // cannot escape it. Overridable so a test (or the desktop app pointing at a
  // real project) can choose the root without patching code.
  const WORKSPACE = process.env.TRHA_WORKSPACE ?? '/tmp/trha-workspace';
  const runShell = promisify(exec);
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
  ): Promise<void> => {
    const ev: ToolEvent = {
      name, args, status,
      ...(error !== undefined ? { error } : {}),
      ...(startedAt !== undefined ? { durationMs: Date.now() - startedAt } : {}),
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
  const resolveReadPath = (raw: unknown, base = WORKSPACE): string | null => {
    if (typeof raw !== 'string' || !raw.trim()) return null;
    return path.isAbsolute(raw) ? path.resolve(raw) : path.resolve(base, raw);
  };

  /** Recursive file walk with a depth/file cap and the usual noise skipped. */
  const walkFiles = async (dir: string, cap: number): Promise<string[]> => {
    const out: string[] = [];
    const skip = new Set(['node_modules', '.git', 'dist', 'dist-newstyle', '.lake', 'target']);
    const walk = async (d: string, depth: number): Promise<void> => {
      if (out.length >= cap || depth > 12) return;
      let entries;
      try { entries = await readdir(d, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        if (out.length >= cap) return;
        if (e.name.startsWith('.') && e.isDirectory()) continue;
        const full = path.join(d, e.name);
        if (e.isDirectory()) {
          if (skip.has(e.name)) continue;
          await walk(full, depth + 1);
        } else if (e.isFile()) {
          out.push(full);
        }
      }
    };
    await walk(dir, 0);
    return out;
  };

  /** Minimal glob: `**` spans directories, `*`/`?` stay within a segment. */
  const globToRegExp = (pattern: string): RegExp => {
    let re = '';
    for (let i = 0; i < pattern.length; i++) {
      const ch = pattern[i];
      if (ch === '*') {
        if (pattern[i + 1] === '*') {
          re += '.*';
          i += 1;
          if (pattern[i + 1] === '/') i += 1;
        } else {
          re += '[^/]*';
        }
      } else if (ch === '?') {
        re += '[^/]';
      } else {
        re += ch !== undefined && '.+^${}()|[]\\'.includes(ch) ? `\\${ch}` : ch;
      }
    }
    return new RegExp(`^${re}$`);
  };

  const workspaceRelative = (raw: string, base = WORKSPACE): string =>
    path.isAbsolute(raw) ? raw : path.join(base, raw);

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
    // 权限规则引擎：deny > ask > allow（显式规则覆盖，沙箱兜底文件边界）
    const verdict = decidePermission(name, argsObj);
    if (verdict.action === 'deny') return `ERROR: ${verdict.reason}`;
    if (verdict.action === 'ask') return `REQUIRE_APPROVAL: ${verdict.reason}`;
    if (name === 'bash') {
      const cmd = typeof argsObj.command === 'string' ? argsObj.command : '';
      if (!cmd.trim()) return 'ERROR: missing command';
      if (argsObj.background === true) {
        if (!sessionId) return 'ERROR: background jobs need a session';
        const id = startJob(
          { workspace: cwd, state: {}, jobs: jobsFor(sessionId), sessionId },
          cmd,
        );
        return `OK: started ${id} (use job_output to read it)`;
      }
      try {
        const { stdout, stderr } = await runShell(cmd, {
          cwd, timeout: 120_000, maxBuffer: 4 * 1024 * 1024,
        });
        return limitOutput(`exit 0\n${stdout}${stderr ? `\n[stderr]\n${stderr}` : ''}`);
      } catch (e) {
        const err = e as { code?: number; stdout?: string; stderr?: string; message: string };
        return limitOutput(`exit ${err.code ?? 1}\n${err.stdout ?? ''}${err.stderr ? `\n[stderr]\n${err.stderr}` : ''}`
          + (err.stdout || err.stderr ? '' : `\n${err.message}`));
      }
    }
    if (name === 'read') {
      const target = resolveReadPath(argsObj.path, cwd);
      if (!target) return 'ERROR: missing/invalid path argument';
      try {
        const text = await readFile(target, 'utf8');
        const lines = text.split('\n');
        const offset = Number(argsObj.offset);
        const limit = Number(argsObj.limit);
        const start = Number.isFinite(offset) && offset > 0 ? Math.floor(offset) - 1 : 0;
        const count = Number.isFinite(limit) && limit > 0 ? Math.floor(limit) : lines.length;
        const slice = lines.slice(start, start + count);
        return limitOutput(slice.map((l, i) => `${start + i + 1}\t${l}`).join('\n'));
      } catch (e) {
        return `ERROR: ${(e as Error).message}`;
      }
    }
    if (name === 'write' || name === 'append_file') {
      if (typeof argsObj.path !== 'string') return 'ERROR: path must be a string';
      // Relative paths are relative to the *workspace*, not to whatever cwd the
      // scheduler happens to have — the model has no way to know the latter,
      // and "path escapes the workspace" for "hello.txt" is a dead end.
      const target = await confineWritePath(WORKSPACE, workspaceRelative(argsObj.path, cwd), extraWriteRoots);
      if (!target) return 'ERROR: path escapes the workspace';
      const rawContent = argsObj.content;
      if (rawContent === undefined || rawContent === null) return 'ERROR: missing content';
      const content = typeof rawContent === 'string' ? rawContent : JSON.stringify(rawContent);
      try {
        if (name === 'write') {
          await mkdir(path.dirname(target), { recursive: true });
          await writeFile(target, content, 'utf8');
        } else {
          await appendFile(target, content, 'utf8');
        }
        return `OK: ${name} -> ${target} (${content.length} chars)`;
      } catch (e) {
        return `ERROR: ${(e as Error).message}`;
      }
    }
    if (name === 'edit') {
      if (typeof argsObj.path !== 'string') return 'ERROR: path must be a string';
      const oldString = argsObj.old_string;
      const newString = argsObj.new_string;
      if (typeof oldString !== 'string' || oldString === '') return 'ERROR: old_string is required';
      if (typeof newString !== 'string') return 'ERROR: new_string is required';
      const target = await confineWritePath(WORKSPACE, workspaceRelative(argsObj.path, cwd), extraWriteRoots);
      if (!target) return 'ERROR: path escapes the workspace';
      try {
        const before = await readFile(target, 'utf8');
        const parts = before.split(oldString);
        const hits = parts.length - 1;
        if (hits === 0) return `ERROR: old_string not found in ${target}`;
        if (hits > 1 && argsObj.replace_all !== true) {
          return `ERROR: old_string matches ${hits} times in ${target}; pass replace_all or make it unique`;
        }
        const after = argsObj.replace_all === true
          ? parts.join(newString)
          : [parts[0], ...parts.slice(1)].join(newString);
        await writeFile(target, after, 'utf8');
        return `OK: edit -> ${target} (${hits} replacement${hits === 1 ? '' : 's'})`;
      } catch (e) {
        return `ERROR: ${(e as Error).message}`;
      }
    }
    if (name === 'glob') {
      if (typeof argsObj.pattern !== 'string' || !argsObj.pattern.trim()) {
        return 'ERROR: pattern is required';
      }
      const root = typeof argsObj.path === 'string' ? argsObj.path : '.';
      const dir = resolveReadPath(root, cwd);
      if (!dir) return 'ERROR: path escapes the workspace';
      try {
        const found = await walkFiles(dir, 4000);
        const re = globToRegExp(argsObj.pattern);
        const hits = found
          .filter(f => re.test(path.relative(dir, f)))
          .slice(0, 200)
          .map(f => path.relative(dir, f));
        return hits.length ? hits.join('\n') : '(no matches)';
      } catch (e) {
        return `ERROR: ${(e as Error).message}`;
      }
    }
    if (name === 'grep') {
      if (typeof argsObj.pattern !== 'string' || !argsObj.pattern) return 'ERROR: pattern is required';
      let re: RegExp;
      try {
        re = new RegExp(argsObj.pattern, 'm');
      } catch (e) {
        return `ERROR: invalid pattern: ${(e as Error).message}`;
      }
      const dir = resolveReadPath(typeof argsObj.path === 'string' ? argsObj.path : '.', cwd);
      if (!dir) return 'ERROR: path escapes the workspace';
      const only = typeof argsObj.glob === 'string' ? globToRegExp(argsObj.glob) : null;
      try {
        const files = await walkFiles(dir, 4000);
        const out: string[] = [];
        for (const f of files) {
          const rel = path.relative(dir, f);
          if (only && !only.test(rel)) continue;
          let text: string;
          try { text = await readFile(f, 'utf8'); } catch { continue; }
          if (text.includes('\u0000')) continue;      // binary
          const lines = text.split('\n');
          for (let i = 0; i < lines.length; i++) {
            if (re.test(lines[i] ?? '')) {
              out.push(`${rel}:${i + 1}:${(lines[i] ?? '').slice(0, 300)}`);
              if (out.length >= 200) break;
            }
          }
          if (out.length >= 200) break;
        }
        return out.length ? out.join('\n') : '(no matches)';
      } catch (e) {
        return `ERROR: ${(e as Error).message}`;
      }
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
    target: { provider?: string | undefined; model?: string | undefined; genParams?: { temperature?: number | undefined; topP?: number | undefined; maxTokens?: number | undefined } | undefined } = {},
    onDelta?: (text: string) => void,
  ): Promise<string> => {
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
    const toolsBase = (plugins.service('tools') as { list(): BridgeToolSpec[] }).list();
    const toolsCfg = (await plugins.runWaterfall('agent:tools', toolsBase)) as BridgeToolSpec[];
    session.messages.push({ role: 'user', content: message });
    events.emit('agent:message', { sessionId: session.id, role: 'user', content: message });
    emitSafe(plugins.emitMessageSend(session.id, { role: 'user', content: message }));

    let lastCallKey = '';
    let sameCallRepeats = 0;
    for (let round = 0; round < maxToolRounds; round++) {
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
        const request = {
          messages: withSystemPrompt(mode, target.model ?? 'deepseek-flash',
                                     session.cwd ?? WORKSPACE, session.messages),
          tools: toolsCfg,
          model: target.model, provider: target.provider,
          genParams: target.genParams,
          // Same key the kernel session was registered under, so this round
          // updates projections/FSM instead of running statelessly.
          sessionId: session.id,
        };
        // A kernel without the streaming endpoint — or a wire that cannot
        // stream — still answers: fall back to the blocking call instead of
        // failing the whole step.
        response = onDelta
          ? await bridge.queryModelStream(request, onDelta)
              .catch(() => bridge.queryModel(request))
          : await bridge.queryModel(request);
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
        const output = await executeTool(call, session.id);
        // ask 权限规则：暂停执行并发起确认（批准后重放该工具）
        if (output.startsWith('REQUIRE_APPROVAL:')) {
          await emitToolLifecycle(session.id, call.name, parseToolArgs(call), 'failed', started, output);
          session.pendingApproval = { message: output };
          (session as { pendingToolCall?: ToolCallData | undefined }).pendingToolCall = call;
          events.emit('agent:plan', { sessionId: session.id, status: 'awaiting_approval', message: output });
          return `awaiting_approval: ${output}`;
        }
        // A provider requires every tool_calls message to be followed by a tool
        // message per call id before anything else. So the tool result goes in
        // first, and *then* any marker-derived message (a card, a question).
        const failed = output.startsWith('ERROR');
        await emitToolLifecycle(session.id, call.name, parseToolArgs(call),
          failed ? 'failed' : 'succeeded', started, failed ? output : undefined);
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
          session.pendingApproval = { message: plan };
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
    const { sessionId, message, requireApproval, provider, model, temperature, topP, maxTokens } = req.body;
    const genParams = temperature !== undefined || topP !== undefined || maxTokens !== undefined
      ? { temperature, topP, maxTokens }
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
    if (requireApproval) {
      session.pendingApproval = { message };
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
    const reply = await runTurn(session, message, { provider, model, genParams },
      text => events.emit('agent:delta', { sessionId: session.id, text }));
    res.json({
      reply, messages: session.messages, mode: session.mode,
      ...(stepConstraint ? { constraint: stepConstraint } : {}),
    });
  });

  // ── Approval decisions (Phase 2 S1) ───────────────────────────────────

  app.post('/api/session/:id/decision', async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });

    // A plan decision: the kernel owns plans, so this is a pure forward. Doing
    // it before the local gate keeps the two machines from both answering.
    const planAction = req.body?.action;
    if (typeof planAction === 'string') {
      try {
        const answer = await bridge.decidePlan(session.id, planAction);
        events.emit('agent:decision', { sessionId: session.id, action: planAction });
        return res.json({ ...answer, mode: session.mode });
      } catch (e) {
        return res.status(502).json({ error: `kernel plan decision failed: ${String(e)}` });
      }
    }

    const pending = session.pendingApproval;
    if (!pending) return res.status(400).json({ error: 'No pending approval' });
    const approve = req.body?.approve === true;
    session.pendingApproval = null;
    // Release the kernel's barrier before running anything: if it kept the
    // session parked, the next step would be refused.
    void bridge.decideApproval(session.id, approve).catch(e =>
      console.error(`kernel approval decision ${session.id}:`, e));
    events.emit('agent:decision', { sessionId: session.id, approve });
    if (!approve) {
      return res.json({ status: 'denied', mode: session.mode });
    }
    // ask 工具确认后批准 → 重放该工具结果（权限规则 ask 分支）
    const pendingCall = (session as { pendingToolCall?: ToolCallData | undefined }).pendingToolCall;
    if (pendingCall) {
      const output = await executeTool(pendingCall);
      (session as { pendingToolCall?: ToolCallData | undefined }).pendingToolCall = undefined;
      session.messages.push({ role: 'tool', tool_call_id: pendingCall.id, content: output });
      const reply = await runTurn(session, pending.message);
      return res.json({ status: 'approved', tool: pendingCall.name, output, reply, messages: session.messages, mode: session.mode });
    }
    const reply = await runTurn(session, pending.message);
    res.json({ status: 'approved', reply, messages: session.messages, mode: session.mode });
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
      const reply = await runTurn(session, answer, {});
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
    }
  };

  const spawnAgent = async (
    parent: SchedulerSession, task: string, name?: string,
  ): Promise<{ id: string; reply: string }> => {
    const depth = (parent.depth ?? 0) + 1;
    if (depth > maxSubagentDepth) {
      throw new Error(`subagent depth limit reached (${maxSubagentDepth})`);
    }
    const slug = (name ?? 'sub').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 24) || 'sub';
    const id = `${parent.id}#${slug}-${++subagentSeq}`;
    const child: SchedulerSession = {
      id,
      mode: parent.mode,
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
      const reply = await runTurn(child, task);
      await persistSession(child);
      return { id, reply };
    } finally {
      events.emit('agent:exit', { sessionId: parent.id, child: id });
    }
  };

  const agentHooksFor = (session: SchedulerSession): AgentHooks => ({
    spawn: (task, name) => spawnAgent(session, task, name),
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
      if (inFlight.has(id)) {
        await persistSession(target);
        return { delivered: true };
      }
      const reply = await runTurn(target, text);
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
      const reply = await runTurn(session, s.prompt, {});
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

  const tickSchedules = async (): Promise<void> => {
    if (ticking) return;
    ticking = true;
    try {
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

    events.on('agent:message', handler);
    events.on('agent:delta', handler);
    events.on('agent:plan', handler);
    events.on('agent:decision', handler);
    events.on('tool:update', handler);
    req.on('close', () => {
      events.off('agent:message', handler);
      events.off('agent:delta', handler);
      events.off('agent:plan', handler);
      events.off('agent:decision', handler);
      events.off('tool:update', handler);
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
  const { app } = createServer(config);
  return new Promise<void>((resolve) => {
    const onListen = () => {
      const handshake = config.socketPath
        ? { v: 1, name: 'trha-scheduler', port: 0, socket: config.socketPath }
        : { v: 1, name: 'trha-scheduler', port: config.port };
      process.stdout.write(JSON.stringify(handshake) + '\n');
      if (config.socketPath) {
        console.error(`Scheduler listening on ${config.socketPath}`);
      } else {
        console.error(`Scheduler listening on port ${config.port}`);
      }
      console.error(`Modes: ${Object.keys(MODES).join(', ')}`);
      console.error(`Tools: ${ALL_TOOLS.length} registered`);
      resolve();
    };
    if (config.socketPath) {
      // remove a stale socket file from a previous run, then listen on UDS
      try { rmSync(config.socketPath); } catch { /* ignore */ }
      app.listen(config.socketPath, onListen);
      process.on('exit', () => {
        try { rmSync(config.socketPath ?? ''); } catch { /* ignore */ }
      });
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
