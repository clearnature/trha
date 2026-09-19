// Scheduler HTTP Server
// Exposes the scheduler as an HTTP API for the Desktop app
// Mode system ported from deepseek-harness standard/ptc/minimal/cordis presets

import express from 'express';
import cors from 'cors';
import { HaskellBridge } from '../Bridge/Haskell.js';
import type { BridgeToolSpec, ToolCallData } from '../Bridge/Haskell.js';
import { findTool, toToolSpecs } from './toolCatalog.js';
import { confineWritePath, limitOutput } from './toolGuard.js';
import { decidePermission, setPermissionRules, compileRules, getPermissionRules } from '../Permission/permissionRules.js';
import { EventEmitter } from '../Utils/EventEmitter.js';
import { Plugin, PluginManager } from '../Plugins/Plugin.js';
import { loadPluginsFrom } from '../Plugins/loader.js';
import { fileURLToPath } from 'node:url';
import { readFileSync, rmSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { loadPin, loadSessions, removeSessionFile, savePin, saveSession } from './stateStore.js';
import { startPluginWatcher } from '../Plugins/watcher.js';
import { mkdir, readFile, writeFile, appendFile } from 'node:fs/promises';
import path from 'node:path';

export interface ServerConfig {
  port: number;
  /** Listen address; loopback only by default (host gate). */
  host?: string;
  token: string;
  haskellHost: string;
  haskellPort: number;
  /** Plugins registered at startup (Phase 3 plugin architecture). */
  plugins?: Plugin[];
  /** Directory of plugin modules (*.js/*.mjs, default-export Plugin) loaded at startup. */
  pluginsDir?: string;
  /** Hot-reload the plugins directory (default true). */
  watchPlugins?: boolean;
  /** Directory for server-side session persistence (absent = memory only). */
  stateDir?: string;
  /** Directory of static /studio pages (default: scheduler/studio-public). */
  studioDir?: string;
  /** Unix domain socket for host-local IPC (no TCP network surface). */
  socketPath?: string;
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
  tool_calls?: unknown[];
  tool_call_id?: string;
  [key: string]: unknown;
}

interface SchedulerSession {
  id: string;
  mode: string;
  messages: SessionMessage[];
  pendingApproval: { message: string } | null;
  createdAt: Date;
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

const MODES: Record<string, ModeConfig> = {
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
  if (config.stateDir) {
    void loadSessions(config.stateDir).then(records => {
      for (const r of records) {
        sessions.set(r.sessionId, {
          id: r.sessionId,
          mode: r.mode,
          messages: r.messages as SessionMessage[],
          pendingApproval: r.pendingApproval,
          createdAt: new Date(r.createdAt),
        });
      }
    }).catch(e => console.error('session restore failed:', e));
  }

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

  const models = [
    { name: 'mimo-v2.5-pro', description: 'MIMO v2.5 Pro', contextSize: 131072 },
    { name: 'deepseek-chat', description: 'DeepSeek Chat', contextSize: 65536 },
    { name: 'deepseek-reasoner', description: 'DeepSeek Reasoner', contextSize: 65536 },
    { name: 'qwen3.8-27b', description: 'Qwen 3.8 27B (local)', contextSize: 32768 },
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
        body: body === undefined ? undefined : JSON.stringify(body),
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
  // optional disk persistence (G2): no-op without stateDir
  const persistSession = (session: SchedulerSession) => {
    if (!config.stateDir) return;
    void saveSession(config.stateDir, session).catch(e =>
      console.error(`persist session ${session.id}:`, e));
  };

  app.post('/api/session/start', (req, res) => {
    const mode = req.body.mode || 'standard';
    if (!MODES[mode]) return res.status(400).json({ error: `Unknown mode: ${mode}` });
    const sessionId = `session-${Date.now()}`;
    const created = { id: sessionId, mode, messages: [] as SessionMessage[], pendingApproval: null, createdAt: new Date() };
    sessions.set(sessionId, created);
    persistSession(created);
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
  // Host-side tools live under the orchestration workspace so file
  // mutations cannot escape /tmp/trha-workspace.
  const WORKSPACE = '/tmp/trha-workspace';
  // 沙箱「允许写入路径」（设置页配置的额外可信写目录；限制放宽，默认仅工作区）
  let extraWriteRoots: string[] = [];
  const AGENT_TOOLS: BridgeToolSpec[] = toToolSpecs();
  const MAX_TOOL_ROUNDS = 5;

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

  const inWorkspace = (raw: unknown): string | null => {
    if (typeof raw !== 'string') return null;
    const resolved = path.resolve(raw);
    return resolved.startsWith(path.resolve(WORKSPACE) + '/') ? resolved : null;
  };

  const executeTool = async (c: ToolCallData): Promise<string> => {
    let argsObj: Record<string, unknown> = {};
    try {
      argsObj = JSON.parse(c.arguments) as Record<string, unknown>;
    } catch {
      return `ERROR: malformed arguments for ${c.name}`;
    }
    // 权限规则引擎：deny > ask > allow（显式规则覆盖，沙箱兜底文件边界）
    const verdict = decidePermission(c.name, argsObj);
    if (verdict.action === 'deny') return `ERROR: ${verdict.reason}`;
    if (verdict.action === 'ask') return `REQUIRE_APPROVAL: ${verdict.reason}`;
    if (c.name === 'read_file') {
      const target = inWorkspace(argsObj.path) ?? (typeof argsObj.path === 'string' ? argsObj.path : null);
      if (!target) return 'ERROR: missing/invalid path argument';
      try {
        return limitOutput(await readFile(target, 'utf8'));
      } catch (e) {
        return `ERROR: ${(e as Error).message}`;
      }
    }
    if (c.name === 'write_file' || c.name === 'append_file') {
      if (typeof argsObj.path !== 'string') return 'ERROR: path must be a string';
      // canonical, symlink-free target confined to the workspace
      const target = await confineWritePath(WORKSPACE, argsObj.path, extraWriteRoots);
      if (!target) return 'ERROR: path escapes the workspace';
      // Small local models sometimes double-encode or nest the content
      // value; tolerate any JSON value by stringifying non-strings.
      const rawContent = argsObj.content;
      if (rawContent === undefined || rawContent === null) return 'ERROR: missing content';
      const content = typeof rawContent === 'string' ? rawContent : JSON.stringify(rawContent);
      try {
        if (c.name === 'write_file') {
          await writeFile(target, content, 'utf8');
        } else {
          await appendFile(target, content, 'utf8');
        }
        return `OK: ${c.name} -> ${target} (${content.length} chars)`;
      } catch (e) {
        return `ERROR: ${(e as Error).message}`;
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
    target: { provider?: string; model?: string; genParams?: { temperature?: number; topP?: number; maxTokens?: number } } = {},
    onDelta?: (text: string) => void,
  ): Promise<string> => {
    const mode = MODES[session.mode];
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

    for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
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
        const request = {
          messages: session.messages, tools: toolsCfg,
          model: target.model, provider: target.provider,
          genParams: target.genParams,
        };
        // A kernel without the streaming endpoint — or a wire that cannot
        // stream — still answers: fall back to the blocking call instead of
        // failing the whole step.
        response = onDelta
          ? await bridge.queryModelStream(request, onDelta)
              .catch(() => bridge.queryModel(request))
          : await bridge.queryModel(request);
        if (response.constraint) stepConstraint = response.constraint;
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
      session.messages.push({
        role: 'assistant', content: response.reply,
        tool_calls: calls.map(c => ({ id: c.id, type: 'function', function: { name: c.name, arguments: c.arguments } })),
      });
      for (const call of calls) {
        const started = Date.now();
        await emitToolLifecycle(session.id, call.name, parseToolArgs(call), 'running');
        const output = await executeTool(call);
        // ask 权限规则：暂停执行并发起确认（批准后重放该工具）
        if (output.startsWith('REQUIRE_APPROVAL:')) {
          await emitToolLifecycle(session.id, call.name, parseToolArgs(call), 'failed', started, output);
          session.pendingApproval = { message: output };
          (session as { pendingToolCall?: ToolCallData }).pendingToolCall = call;
          events.emit('agent:plan', { sessionId: session.id, status: 'awaiting_approval', message: output });
          return `awaiting_approval: ${output}`;
        }
        const failed = output.startsWith('ERROR');
        await emitToolLifecycle(session.id, call.name, parseToolArgs(call),
          failed ? 'failed' : 'succeeded', started, failed ? output : undefined);
        session.messages.push({ role: 'tool', tool_call_id: call.id, content: output });
      }
    }

    const exhausted = `(tool loop exhausted after ${MAX_TOOL_ROUNDS} rounds)`;
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

    // Approval gate: hold the request until the host decides.
    if (requireApproval) {
      session.pendingApproval = { message };
      events.emit('agent:plan', { sessionId, status: 'awaiting_approval', message });
      return res.json({ status: 'awaiting_approval', pending: { message }, mode: session.mode });
    }

    session.pendingApproval = null; // a regular step clears any stale gate
    // A3: stream the answer to whoever listens on this session's SSE channel.
    const reply = await runStep(session, message, { provider, model, genParams },
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
    const pending = session.pendingApproval;
    if (!pending) return res.status(400).json({ error: 'No pending approval' });
    const approve = req.body?.approve === true;
    session.pendingApproval = null;
    events.emit('agent:decision', { sessionId: session.id, approve });
    if (!approve) {
      return res.json({ status: 'denied', mode: session.mode });
    }
    // ask 工具确认后批准 → 重放该工具结果（权限规则 ask 分支）
    const pendingCall = (session as { pendingToolCall?: ToolCallData }).pendingToolCall;
    if (pendingCall) {
      const output = await executeTool(pendingCall);
      (session as { pendingToolCall?: ToolCallData }).pendingToolCall = undefined;
      session.messages.push({ role: 'tool', tool_call_id: pendingCall.id, content: output });
      const reply = await runStep(session, pending.message);
      return res.json({ status: 'approved', tool: pendingCall.name, output, reply, messages: session.messages, mode: session.mode });
    }
    const reply = await runStep(session, pending.message);
    res.json({ status: 'approved', reply, messages: session.messages, mode: session.mode });
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
    const { model, messages, stream, max_tokens, temperature, tools } = req.body;

    if (!messages || !Array.isArray(messages) || messages.length === 0) {
      return res.status(400).json({ error: { message: 'messages is required', type: 'invalid_request_error' } });
    }

    const modelInfo = models.find(m => m.name === model) || models[0];
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
    const { model, messages, max_tokens, stream, system, temperature } = req.body;

    if (!messages || !Array.isArray(messages) || messages.length === 0) {
      return res.status(400).json({
        type: 'error',
        error: { type: 'invalid_request_error', message: 'messages is required' },
      });
    }

    const modelInfo = models.find(m => m.name === model) || models[0];
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
    const { model, input, stream, instructions, tools: respTools } = req.body;

    if (!input) {
      return res.status(400).json({ error: { message: 'input is required', type: 'invalid_request_error' } });
    }

    const modelInfo = models.find(m => m.name === model) || models[0];
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

  return { app, config };
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
