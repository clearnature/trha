// Scheduler HTTP Server
// Exposes the scheduler as an HTTP API for the Desktop app
// Mode system ported from deepseek-harness standard/ptc/minimal/cordis presets

import express from 'express';
import cors from 'cors';
import { HaskellBridge } from '../Bridge/Haskell.js';
import { EventEmitter } from '../Utils/EventEmitter.js';

export interface ServerConfig {
  port: number;
  token: string;
  haskellHost: string;
  haskellPort: number;
}

export const defaultServerConfig: ServerConfig = {
  port: 3456,
  token: process.env.GH_HARNESS_TOKEN || 'dev-token',
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

export function createServer(config: ServerConfig = defaultServerConfig) {
  const app = express();
  const events = new EventEmitter();
  const bridge = new HaskellBridge({ host: config.haskellHost, port: config.haskellPort });

  app.use(cors());
  app.use(express.json());

  // Token authentication middleware
  // Exempt /health and /v1/* (OpenAI/Anthropic/Responses protocols use their own auth)
  app.use((req, res, next) => {
    if (req.path === '/health' || req.path.startsWith('/v1/')) return next();
    const auth = req.headers.authorization;
    const token = req.query.token as string;
    if (auth !== `Bearer ${config.token}` && token !== config.token) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
    next();
  });

  // ── Health ────────────────────────────────────────────────────────────

  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', version: '0.1.0', modes: Object.keys(MODES) });
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

  // ── Sessions ──────────────────────────────────────────────────────────

  const sessions = new Map<string, {
    id: string;
    mode: string;
    messages: Array<{ role: string; content: string }>;
    createdAt: Date;
  }>();

  app.post('/api/session/start', (req, res) => {
    const mode = req.body.mode || 'standard';
    if (!MODES[mode]) return res.status(400).json({ error: `Unknown mode: ${mode}` });
    const sessionId = `session-${Date.now()}`;
    sessions.set(sessionId, { id: sessionId, mode, messages: [], createdAt: new Date() });
    events.emit('session:created', { sessionId, mode });
    res.json({ sessionId, mode });
  });

  app.get('/api/session/:id', (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    res.json(session);
  });

  app.get('/api/sessions', (_req, res) => {
    res.json(Array.from(sessions.values()));
  });

  // ── Agent step ────────────────────────────────────────────────────────

  app.post('/api/agent/step', async (req, res) => {
    const { sessionId, message } = req.body;
    const session = sessions.get(sessionId);
    if (!session) return res.status(404).json({ error: 'Session not found' });

    const mode = MODES[session.mode];
    session.messages.push({ role: 'user', content: message });
    events.emit('agent:message', { sessionId, role: 'user', content: message });

    try {
      const response = await bridge.queryModel({
        messages: session.messages.map(m => [m.role, m.content] as [string, string]),
      });
      const reply = response.chunks.join('');
      session.messages.push({ role: 'assistant', content: reply });
      events.emit('agent:message', { sessionId, role: 'assistant', content: reply });
      res.json({ reply, messages: session.messages, mode: session.mode });
    } catch {
      // Fallback: echo with mode context
      const reply = mode.ptc.enabled
        ? `[PTC] run_code(${message.slice(0, 50)}...)`
        : `[${session.mode}] Received: ${message}`;
      session.messages.push({ role: 'assistant', content: reply });
      events.emit('agent:message', { sessionId, role: 'assistant', content: reply });
      res.json({ reply, messages: session.messages, mode: session.mode });
    }
  });

  // ── SSE event stream ──────────────────────────────────────────────────

  app.get('/api/events/:sessionId', (req, res) => {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    });

    const handler = (data: unknown) => {
      res.write(`data: ${JSON.stringify(data)}\n\n`);
    };

    events.on('agent:message', handler);
    req.on('close', () => {
      events.off('agent:message', handler);
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
        const response = await bridge.queryModel({ messages: bridgeMessages });
        const fullText = response.chunks.join('');

        // Send as streaming chunks
        const words = fullText.split(/(\s+)/);
        for (let i = 0; i < words.length; i++) {
          const chunk = {
            id: requestId,
            object: 'chat.completion.chunk',
            created: Math.floor(Date.now() / 1000),
            model: modelInfo.name,
            choices: [{
              index: 0,
              delta: i === 0 ? { role: 'assistant', content: words[i] } : { content: words[i] },
              finish_reason: null,
            }],
          };
          res.write(`data: ${JSON.stringify(chunk)}\n\n`);
        }

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
      const fullText = response.chunks.join('');

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
        const response = await bridge.queryModel({ messages: bridgeMessages });
        const fullText = response.chunks.join('');

        // Send text in chunks
        const words = fullText.split(/(\s+)/);
        for (const word of words) {
          res.write(`event: content_block_delta\ndata: ${JSON.stringify({
            type: 'content_block_delta',
            index: 0,
            delta: { type: 'text_delta', text: word },
          })}\n\n`);
        }
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
      const fullText = response.chunks.join('');

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
        const response = await bridge.queryModel({ messages: bridgeMessages });
        const fullText = response.chunks.join('');

        // Send text delta
        const words = fullText.split(/(\s+)/);
        for (const word of words) {
          res.write(`event: response.output_text.delta\ndata: ${JSON.stringify({
            type: 'response.output_text.delta',
            output_index: outputIndex,
            content_index: 0,
            delta: word,
          })}\n\n`);
        }
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
      const fullText = response.chunks.join('');

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

export function startServer(config: ServerConfig = defaultServerConfig) {
  const { app } = createServer(config);
  return new Promise<void>((resolve) => {
    app.listen(config.port, () => {
      console.log(`Scheduler listening on port ${config.port}`);
      console.log(`Modes: ${Object.keys(MODES).join(', ')}`);
      console.log(`Tools: ${ALL_TOOLS.length} registered`);
      resolve();
    });
  });
}
