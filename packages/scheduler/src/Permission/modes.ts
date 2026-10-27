// Session permission modes (Reasonix Studio parity:
// internal/frontend/tui/posture.go).
//
// Five user-facing postures, cycled by Shift+Tab:
//   read-only → ask → auto → YOLO → plan → read-only
// Ctrl+Y toggles YOLO without leaving plan mode.
//
// The mode decides what executeTool does *before* the rule engine runs:
//   read-only : only an explicit allow-list of read-only tools runs.
//   ask       : read-only tools run; everything else requires confirmation.
//   auto      : the per-user deny/ask/allow rules decide.
//   yolo      : everything runs; an explicit deny rule still wins.
//   plan      : same allow-list as read-only, with planMode set.
//
// `deny` from the rule engine always wins, in every mode.

export type PermissionMode = 'read-only' | 'ask' | 'auto' | 'yolo' | 'plan';

export const MODE_CYCLE: PermissionMode[] = ['read-only', 'ask', 'auto', 'yolo', 'plan'];

/** Tools that only observe (files/session/network read, planning state). */
const READ_ONLY_TOOLS = new Set<string>([
  // filesystem reads
  'read', 'read_file', 'read_image', 'view_image', 'glob', 'grep', 'codesearch',
  // network reads
  'web_fetch', 'webfetch', 'web_search', 'websearch',
  // MCP / LSP / plugin introspection
  'list_mcp_resources', 'list_mcp_resource_templates', 'read_mcp_resource',
  'lsp', 'plugin_manager', 'cordis_inspect_list', 'cordis_inspect_query',
  // sessions / agents observation
  'list_agents', 'list_subagent_models', 'wait_agent',
  'session_search', 'session_trace',
  'session_event_read', 'session_event_search', 'session_event_trace',
  // jobs: list/output are reads; kill is not in this set
  'job_list', 'job_output',
  // skills: loading a skill file is a read
  'skill',
  // session-local planning state (no filesystem / process side effects)
  'todo_write', 'get_goal', 'create_goal', 'update_goal',
  'team_task_create', 'team_task_list', 'team_task_get', 'team_task_update',
  'schedule_create', 'schedule_list', 'schedule_update', 'schedule_delete',
  'working_directory',
  // UI-side effects
  'present', 'ask_user_question', 'exit_plan_mode',
]);

export function isReadOnlyTool(name: string): boolean {
  return READ_ONLY_TOOLS.has(name);
}

/** The next mode in the Shift+Tab cycle. */
export function nextMode(mode: PermissionMode): PermissionMode {
  const i = MODE_CYCLE.indexOf(mode);
  return MODE_CYCLE[(i + 1) % MODE_CYCLE.length] ?? 'read-only';
}

/**
 * Ctrl+Y semantics: from YOLO, restore the preset active before it (ask is
 * Studio's fallback); otherwise enter YOLO and remember the current preset.
 * Plan mode is a separate flag and is left untouched.
 */
export function toggleYolo(
  mode: PermissionMode,
  restore: PermissionMode | null,
): { mode: PermissionMode; restore: PermissionMode | null } {
  if (mode === 'yolo') {
    const back = restore && restore !== 'yolo' ? restore : 'ask';
    return { mode: back, restore: null };
  }
  const remembered = mode === 'plan' ? 'read-only' : mode;
  return { mode: 'yolo', restore: remembered };
}

export type ModeVerdict =
  | { action: 'allow' }
  | { action: 'deny'; reason: string }
  | { action: 'ask'; reason: string };

/**
 * Apply a permission mode on top of the rule-engine verdict.  An explicit
 * `deny` is never overridden.
 */
export function applyPermissionMode(
  mode: PermissionMode,
  toolName: string,
  ruleVerdict: ModeVerdict,
): ModeVerdict {
  if (ruleVerdict.action === 'deny') return ruleVerdict;
  switch (mode) {
    case 'read-only':
    case 'plan':
      return isReadOnlyTool(toolName)
        ? { action: 'allow' }
        : { action: 'deny', reason: `${mode} mode: ${toolName} is not allowed (Shift+Tab to switch)` };
    case 'ask':
      return isReadOnlyTool(toolName)
        ? { action: 'allow' }
        : { action: 'ask', reason: `ask mode: confirm ${toolName}` };
    case 'yolo':
      return { action: 'allow' };
    case 'auto':
    default:
      return ruleVerdict;
  }
}

/** UI label for a mode (Reasonix's status-line wording). */
export function modeLabel(mode: PermissionMode): string {
  switch (mode) {
    case 'read-only': return 'Read only';
    case 'ask': return 'Ask';
    case 'auto': return 'Auto';
    case 'yolo': return 'YOLO';
    case 'plan': return 'Plan';
  }
}
