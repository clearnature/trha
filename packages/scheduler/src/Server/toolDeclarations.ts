/**
 * Plane + preset metadata for every tool the scheduler exposes.
 *
 * Why this file exists: the handlers are spread over three legacy if-chains
 * (`standardTools.ts`, `extraTools.ts`, and `index.ts` for the core file/shell
 * tools). Declaring the metadata here makes step 2 (host/agent planes) and
 * step 3 (preset filtering) usable *immediately*, while handlers migrate one at
 * a time — a spec without `handler` only contributes metadata, and the entry
 * points fall through to the chains.
 *
 * Plane split follows DSH: `host` rows own process-wide state (subagent registry,
 * session index, schedules, goals, MCP servers) and are shared by every session;
 * `agent` rows are the model-facing tools a preset chooses to mount.
 */
import { declareTool, type ToolPlane } from './toolRegistry.js';

type Preset = string;

/** Presets that get the "always available" file/shell core. */
const CORE: Preset[] = ['standard', 'ptc', 'minimal'];
/** Presets that get the full agent toolset. */
const FULL: Preset[] = ['standard', 'ptc'];
/** Only the standard preset (ptc replaces these with `run_code`). */
const STD: Preset[] = ['standard'];
/** Only the ptc preset. */
const PTC: Preset[] = ['ptc'];

interface Row {
  name: string;
  plane: ToolPlane;
  presets: Preset[];
}

const rows: Row[] = [
  // ── agent-plane: file / shell core (every preset except cordis) ──────
  { name: 'bash', plane: 'agent', presets: CORE },
  { name: 'pwsh', plane: 'agent', presets: CORE },
  { name: 'read', plane: 'agent', presets: CORE },
  { name: 'write', plane: 'agent', presets: CORE },
  { name: 'edit', plane: 'agent', presets: CORE },
  { name: 'grep', plane: 'agent', presets: CORE },
  { name: 'glob', plane: 'agent', presets: CORE },
  { name: 'ask_user_question', plane: 'agent', presets: CORE },

  // ── agent-plane: editing / navigation helpers ────────────────────────
  { name: 'unified_edit', plane: 'agent', presets: FULL },
  { name: 'str_replace_editor', plane: 'agent', presets: FULL },
  { name: 'working_directory', plane: 'agent', presets: FULL },
  { name: 'create_worktree', plane: 'agent', presets: FULL },
  { name: 'load_workspace_dependencies', plane: 'agent', presets: FULL },
  { name: 'read_image', plane: 'agent', presets: FULL },
  { name: 'skill', plane: 'agent', presets: FULL },
  { name: 'present', plane: 'agent', presets: FULL },

  // ── agent-plane: web ────────────────────────────────────────────────
  // `web_fetch` registers its own handler in standardTools.ts; `declareTool`
  // is additive, so its metadata can live here without a name collision.
  { name: 'web_fetch', plane: 'agent', presets: FULL },
  { name: 'web_search', plane: 'agent', presets: FULL },

  // ── agent-plane: plan / todo / delegation tools ──────────────────────
  { name: 'todo_write', plane: 'agent', presets: STD },
  { name: 'exit_plan_mode', plane: 'agent', presets: STD },
  { name: 'workflow', plane: 'agent', presets: STD },
  { name: 'ralph', plane: 'agent', presets: STD },
  { name: 'run_code', plane: 'agent', presets: PTC },

  // ── agent-plane: terminals ──────────────────────────────────────────
  { name: 'terminal_open', plane: 'agent', presets: FULL },
  { name: 'terminal_read', plane: 'agent', presets: FULL },
  { name: 'terminal_send', plane: 'agent', presets: FULL },
  { name: 'terminal_signal', plane: 'agent', presets: FULL },
  { name: 'terminal_close', plane: 'agent', presets: FULL },
  { name: 'terminal_list', plane: 'agent', presets: FULL },

  // ── agent-plane: browser / stagehand ────────────────────────────────
  { name: 'browser_navigate', plane: 'agent', presets: FULL },
  { name: 'browser_extract', plane: 'agent', presets: FULL },
  { name: 'browser_screenshot', plane: 'agent', presets: FULL },
  { name: 'browser_close', plane: 'agent', presets: FULL },
  { name: 'stagehand_act', plane: 'agent', presets: FULL },
  { name: 'stagehand_extract', plane: 'agent', presets: FULL },
  { name: 'stagehand_navigate', plane: 'agent', presets: FULL },
  { name: 'stagehand_observe', plane: 'agent', presets: FULL },
  { name: 'stagehand_screenshot', plane: 'agent', presets: FULL },
  { name: 'stagehand_tabs', plane: 'agent', presets: FULL },

  // ── host-plane: subagents (process-wide registry) ───────────────────
  { name: 'subagent', plane: 'host', presets: FULL },
  { name: 'spawn_teammate', plane: 'host', presets: FULL },
  { name: 'list_agents', plane: 'host', presets: FULL },
  { name: 'wait_agent', plane: 'host', presets: FULL },
  { name: 'interrupt_agent', plane: 'host', presets: FULL },
  { name: 'send_message', plane: 'host', presets: FULL },
  { name: 'list_subagent_models', plane: 'host', presets: FULL },

  // ── host-plane: team tasks ──────────────────────────────────────────
  { name: 'team_task_create', plane: 'host', presets: FULL },
  { name: 'team_task_get', plane: 'host', presets: FULL },
  { name: 'team_task_list', plane: 'host', presets: FULL },
  { name: 'team_task_update', plane: 'host', presets: FULL },

  // ── host-plane: schedules ───────────────────────────────────────────
  { name: 'schedule_create', plane: 'host', presets: FULL },
  { name: 'schedule_delete', plane: 'host', presets: FULL },
  { name: 'schedule_list', plane: 'host', presets: FULL },
  { name: 'schedule_update', plane: 'host', presets: FULL },

  // ── host-plane: session index ───────────────────────────────────────
  { name: 'session_search', plane: 'host', presets: FULL },
  { name: 'session_trace', plane: 'host', presets: FULL },
  { name: 'session_event_read', plane: 'host', presets: FULL },
  { name: 'session_event_search', plane: 'host', presets: FULL },
  { name: 'session_event_trace', plane: 'host', presets: FULL },

  // ── host-plane: plugins / MCP / LSP ─────────────────────────────────
  { name: 'plugin_manager', plane: 'host', presets: FULL },
  { name: 'plugin_market', plane: 'host', presets: FULL },
  { name: 'cordis_inspect_list', plane: 'host', presets: FULL },
  { name: 'cordis_inspect_query', plane: 'host', presets: FULL },
  { name: 'list_mcp_resources', plane: 'host', presets: FULL },
  { name: 'list_mcp_resource_templates', plane: 'host', presets: FULL },
  { name: 'read_mcp_resource', plane: 'host', presets: FULL },
  { name: 'lsp', plane: 'host', presets: FULL },

  // ── host-plane: goals / background jobs ─────────────────────────────
  { name: 'create_goal', plane: 'host', presets: FULL },
  { name: 'get_goal', plane: 'host', presets: FULL },
  { name: 'update_goal', plane: 'host', presets: FULL },
  { name: 'job_kill', plane: 'host', presets: FULL },
  { name: 'job_list', plane: 'host', presets: FULL },
  { name: 'job_output', plane: 'host', presets: FULL },
];

for (const row of rows) {
  declareTool({ name: row.name, plane: row.plane, presets: row.presets });
}

/** Exposed for diagnostics (`trha sandbox status`-style listings). */
export const DECLARED_TOOL_COUNT = rows.length;
