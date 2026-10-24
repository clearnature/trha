// Tool schema catalog (aligned with deepseek-harness docs/tool-catalog):
// the schema and contract of every host tool live in one module so the
// model-facing tool list, the registry description and the guard rails
// share a single source of truth.
//
// Names follow deepseek-harness (`read`, `write`, `edit`, `glob`, `grep`,
// `bash`) so a model trained on that harness does not have to guess. The older
// `*_file` names stay as aliases in the executor.

export interface ToolDefinition {
  name: string;
  description: string;
  parameters: {
    type: 'object';
    properties: Record<string, unknown>;
    required: string[];
  };
}

/** Canonical tool directory, in the order offered to the model. */
export const toolCatalog: ToolDefinition[] = [
  {
    name: 'bash',
    description: 'Execute a shell command in the workspace (stdout+stderr, exit code included); set background to run it as a job',
    parameters: {
      type: 'object',
      properties: {
        command: { type: 'string' },
        background: { type: 'boolean', description: 'return a job id instead of waiting' },
      },
      required: ['command'],
    },
  },
  {
    name: 'read',
    description: 'Read a file (optionally a line range). Returns numbered lines.',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string' },
        offset: { type: 'number', description: '1-based first line' },
        limit: { type: 'number', description: 'max lines to return' },
      },
      required: ['path'],
    },
  },
  {
    name: 'write',
    description: 'Write a file (creates/overwrites) inside the workspace',
    parameters: {
      type: 'object',
      properties: { path: { type: 'string' }, content: { type: 'string' } },
      required: ['path', 'content'],
    },
  },
  {
    name: 'edit',
    description: 'Replace an exact string in a file; old_string must match exactly once unless replace_all is set',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string' },
        old_string: { type: 'string' },
        new_string: { type: 'string' },
        replace_all: { type: 'boolean' },
      },
      required: ['path', 'old_string', 'new_string'],
    },
  },
  {
    name: 'glob',
    description: 'List files matching a glob pattern (e.g. "src/**/*.ts"), newest first',
    parameters: {
      type: 'object',
      properties: {
        pattern: { type: 'string' },
        path: { type: 'string', description: 'directory to search from' },
      },
      required: ['pattern'],
    },
  },
  {
    name: 'grep',
    description: 'Search file contents with a regular expression; returns path:line:text',
    parameters: {
      type: 'object',
      properties: {
        pattern: { type: 'string' },
        path: { type: 'string', description: 'directory to search from' },
        glob: { type: 'string', description: 'only search files matching this glob' },
      },
      required: ['pattern'],
    },
  },
  {
    name: 'subagent',
    description: 'Run a task in a child agent session and return its final answer',
    parameters: {
      type: 'object',
      properties: {
        task: { type: 'string' },
        name: { type: 'string', description: 'short label used in the child session id' },
      },
      required: ['task'],
    },
  },
  {
    name: 'list_agents',
    description: 'List agent sessions (id, busy/idle, message count, parent)',
    parameters: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'send_message',
    description: 'Send a message to another agent session; runs a turn if it is idle',
    parameters: {
      type: 'object',
      properties: { to: { type: 'string' }, text: { type: 'string' } },
      required: ['to', 'text'],
    },
  },
  {
    name: 'interrupt_agent',
    description: 'Ask an agent to stop at the next round boundary',
    parameters: {
      type: 'object',
      properties: { id: { type: 'string' } },
      required: ['id'],
    },
  },
  {
    name: 'team_task_create',
    description: 'Add a task to the shared team list (visible to every teammate)',
    parameters: {
      type: 'object',
      properties: {
        subject: { type: 'string' },
        description: { type: 'string' },
        assignee: { type: 'string' },
      },
      required: ['subject'],
    },
  },
  { name: 'team_task_list', description: 'List the shared team tasks', parameters: { type: 'object', properties: {}, required: [] } },
  {
    name: 'team_task_update',
    description: 'Update a team task status / assignee / description',
    parameters: {
      type: 'object',
      properties: {
        id: { type: 'string' },
        status: { type: 'string', enum: ['pending', 'in_progress', 'completed'] },
        assignee: { type: 'string' },
        description: { type: 'string' },
      },
      required: ['id'],
    },
  },
  {
    name: 'workflow',
    description: 'Run a list of named subagent tasks in order and return their answers',
    parameters: {
      type: 'object',
      properties: {
        steps: {
          type: 'array',
          items: {
            type: 'object',
            properties: { name: { type: 'string' }, task: { type: 'string' } },
            required: ['task'],
          },
        },
      },
      required: ['steps'],
    },
  },
  {
    name: 'list_mcp_resources',
    description: 'List MCP resources from the configured servers',
    parameters: {
      type: 'object',
      properties: { server: { type: 'string' } },
      required: [],
    },
  },
  {
    name: 'list_mcp_resource_templates',
    description: 'List MCP resource templates from the configured servers',
    parameters: {
      type: 'object',
      properties: { server: { type: 'string' } },
      required: [],
    },
  },
  {
    name: 'read_mcp_resource',
    description: 'Read one MCP resource by URI',
    parameters: {
      type: 'object',
      properties: { uri: { type: 'string' }, server: { type: 'string' } },
      required: ['uri'],
    },
  },
  {
    name: 'lsp',
    description: 'Ask the language server about a file (hover/definition/references/diagnostics/symbols)',
    parameters: {
      type: 'object',
      properties: {
        file: { type: 'string' },
        operation: {
          type: 'string',
          enum: ['hover', 'definition', 'references', 'diagnostics', 'symbols'],
        },
        line: { type: 'number', description: '1-based' },
        character: { type: 'number', description: '1-based' },
      },
      required: ['file', 'operation'],
    },
  },
  {
    name: 'browser_navigate',
    description: 'Open a URL in a headless browser and return the rendered text',
    parameters: {
      type: 'object',
      properties: { url: { type: 'string' } },
      required: ['url'],
    },
  },
  {
    name: 'browser_extract',
    description: 'Read text from the current page (optionally one CSS selector)',
    parameters: {
      type: 'object',
      properties: { selector: { type: 'string' } },
      required: [],
    },
  },
  {
    name: 'browser_screenshot',
    description: 'Take a PNG screenshot of the current page into the workspace',
    parameters: {
      type: 'object',
      properties: { path: { type: 'string' } },
      required: [],
    },
  },
  { name: 'browser_close', description: 'Close the headless browser', parameters: { type: 'object', properties: {}, required: [] } },
  {
    name: 'ask_user_question',
    description: 'Ask the user a question and end this turn; the answer arrives as the next message',
    parameters: {
      type: 'object',
      properties: {
        question: { type: 'string' },
        options: { type: 'array', items: { type: 'string' } },
      },
      required: ['question'],
    },
  },
  {
    name: 'exit_plan_mode',
    description: 'Leave planning and ask for approval to start executing',
    parameters: {
      type: 'object',
      properties: { plan: { type: 'string' } },
      required: [],
    },
  },
  {
    name: 'present',
    description: 'Show a card to the user (title + body) without leaving the turn',
    parameters: {
      type: 'object',
      properties: { title: { type: 'string' }, body: { type: 'string' } },
      required: [],
    },
  },
  {
    name: 'run_code',
    description: 'Run a snippet (python|javascript|bash|lean) in the workspace and return stdout/stderr',
    parameters: {
      type: 'object',
      properties: {
        language: { type: 'string', enum: ['python', 'javascript', 'bash', 'lean'] },
        code: { type: 'string' },
      },
      required: ['language', 'code'],
    },
  },
  {
    name: 'read_image',
    description: 'Read an image file as a data URL (2 MiB cap) for a vision model',
    parameters: {
      type: 'object',
      properties: { path: { type: 'string' } },
      required: ['path'],
    },
  },
  {
    name: 'todo_write',
    description: 'Replace the session todo list. Call only when the list actually changes; an identical rewrite is rejected as UNCHANGED.',
    parameters: {
      type: 'object',
      properties: {
        todos: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              id: { type: 'string' },
              text: { type: 'string' },
              status: { type: 'string', enum: ['pending', 'in_progress', 'completed'] },
            },
            required: ['text'],
          },
        },
      },
      required: ['todos'],
    },
  },
  {
    name: 'create_goal',
    description: 'Set the session goal (objective, optional budget)',
    parameters: {
      type: 'object',
      properties: { objective: { type: 'string' }, budget: { type: 'number' } },
      required: ['objective'],
    },
  },
  { name: 'get_goal', description: 'Read the session goal', parameters: { type: 'object', properties: {}, required: [] } },
  {
    name: 'update_goal',
    description: 'Update the session goal status or objective',
    parameters: {
      type: 'object',
      properties: {
        status: { type: 'string', enum: ['active', 'paused', 'complete'] },
        objective: { type: 'string' },
      },
      required: [],
    },
  },
  {
    name: 'schedule_create',
    description: 'Schedule a prompt for this session; it fires automatically at `at` (repeat with repeat_ms)',
    parameters: {
      type: 'object',
      properties: {
        prompt: { type: 'string' },
        at: { type: 'string', description: 'ISO timestamp or epoch ms' },
        repeat_ms: { type: 'number' },
      },
      required: ['prompt', 'at'],
    },
  },
  { name: 'schedule_list', description: 'List this session schedules', parameters: { type: 'object', properties: {}, required: [] } },
  {
    name: 'schedule_update',
    description: 'Update a schedule (prompt, time, repeat, status)',
    parameters: {
      type: 'object',
      properties: {
        id: { type: 'string' }, prompt: { type: 'string' }, at: { type: 'string' },
        repeat_ms: { type: 'number' }, status: { type: 'string', enum: ['active', 'cancelled'] },
      },
      required: ['id'],
    },
  },
  {
    name: 'schedule_delete',
    description: 'Delete a schedule by id',
    parameters: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] },
  },
  { name: 'job_list', description: 'List background jobs started in this process', parameters: { type: 'object', properties: {}, required: [] } },
  {
    name: 'job_output',
    description: 'Read a background job output (status, exit code, text)',
    parameters: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] },
  },
  {
    name: 'job_kill',
    description: 'Terminate a running background job',
    parameters: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] },
  },
  {
    name: 'skill',
    description: 'List available skills, or load one by name',
    parameters: { type: 'object', properties: { name: { type: 'string' } }, required: [] },
  },
  {
    name: 'web_fetch',
    description: 'Fetch a URL and return its text (HTML is stripped)',
    parameters: { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] },
  },
  {
    name: 'working_directory',
    description: 'Read or change the tool working directory (must stay inside the workspace)',
    parameters: { type: 'object', properties: { path: { type: 'string' } }, required: [] },
  },
  {
    name: 'str_replace_editor',
    description: 'Editor-style file ops: view | create | str_replace | insert',
    parameters: {
      type: 'object',
      properties: {
        command: { type: 'string', enum: ['view', 'create', 'str_replace', 'insert'] },
        path: { type: 'string' },
        file_text: { type: 'string' },
        old_str: { type: 'string' },
        new_str: { type: 'string' },
        insert_line: { type: 'number' },
      },
      required: ['command', 'path'],
    },
  },
  {
    name: 'unified_edit',
    description: 'Alias of str_replace_editor (same commands and semantics)',
    parameters: {
      type: 'object',
      properties: {
        command: { type: 'string' }, path: { type: 'string' },
        file_text: { type: 'string' }, old_str: { type: 'string' },
        new_str: { type: 'string' }, insert_line: { type: 'number' },
      },
      required: ['command', 'path'],
    },
  },
  { name: 'terminal_open', description: 'Open a persistent shell for this session', parameters: { type: 'object', properties: {}, required: [] } },
  {
    name: 'terminal_send',
    description: 'Send input to a persistent shell',
    parameters: { type: 'object', properties: { id: { type: 'string' }, input: { type: 'string' } }, required: ['id', 'input'] },
  },
  {
    name: 'terminal_read',
    description: 'Read a persistent shell output (status + text)',
    parameters: { type: 'object', properties: { id: { type: 'string' }, since: { type: 'number' } }, required: ['id'] },
  },
  {
    name: 'terminal_signal',
    description: 'Send a signal (default SIGINT) to a persistent shell',
    parameters: { type: 'object', properties: { id: { type: 'string' }, signal: { type: 'string' } }, required: ['id'] },
  },
  {
    name: 'terminal_close',
    description: 'Close a persistent shell',
    parameters: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] },
  },
  { name: 'terminal_list', description: 'List persistent shells for this session', parameters: { type: 'object', properties: {}, required: [] } },
  {
    name: 'wait_agent',
    description: 'Wait until an agent is idle (bounded)',
    parameters: { type: 'object', properties: { id: { type: 'string' }, timeout_ms: { type: 'number' } }, required: ['id'] },
  },
  {
    name: 'spawn_teammate',
    description: 'Spawn a named teammate and record it on the shared task list',
    parameters: { type: 'object', properties: { task: { type: 'string' }, name: { type: 'string' } }, required: ['task'] },
  },
  {
    name: 'team_task_get',
    description: 'Read one team task by id',
    parameters: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] },
  },
  {
    name: 'session_search',
    description: 'Search every session transcript for a substring',
    parameters: { type: 'object', properties: { query: { type: 'string' }, limit: { type: 'number' } }, required: ['query'] },
  },
  {
    name: 'session_trace',
    description: 'List a session transcript as a timeline',
    parameters: { type: 'object', properties: { sessionId: { type: 'string' } }, required: [] },
  },
  {
    name: 'session_event_read',
    description: "Read the kernel's event log for a session",
    parameters: { type: 'object', properties: { sessionId: { type: 'string' }, limit: { type: 'number' } }, required: [] },
  },
  {
    name: 'session_event_search',
    description: 'Search the kernel event log for a substring',
    parameters: { type: 'object', properties: { query: { type: 'string' }, sessionId: { type: 'string' } }, required: ['query'] },
  },
  {
    name: 'session_event_trace',
    description: 'Summarise kernel event kinds for a session',
    parameters: { type: 'object', properties: { sessionId: { type: 'string' } }, required: [] },
  },
  {
    name: 'create_worktree',
    description: 'git worktree add a new branch checkout',
    parameters: { type: 'object', properties: { path: { type: 'string' }, branch: { type: 'string' } }, required: ['path'] },
  },
  { name: 'load_workspace_dependencies', description: 'Install/fetch the working directory dependencies', parameters: { type: 'object', properties: {}, required: [] } },
  {
    name: 'pwsh',
    description: 'Run a PowerShell command (requires pwsh)',
    parameters: { type: 'object', properties: { command: { type: 'string' } }, required: ['command'] },
  },
  {
    name: 'web_search',
    description: 'Web search (SearXNG via TRHA_SEARX_URL, else DuckDuckGo HTML)',
    parameters: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] },
  },
  { name: 'list_subagent_models', description: 'List models available to subagents', parameters: { type: 'object', properties: {}, required: [] } },
  { name: 'plugin_manager', description: 'List loaded plugins and their hooks', parameters: { type: 'object', properties: {}, required: [] } },
  { name: 'cordis_inspect_list', description: 'Alias of plugin_manager', parameters: { type: 'object', properties: {}, required: [] } },
  {
    name: 'cordis_inspect_query',
    description: 'Inspect one plugin by name',
    parameters: { type: 'object', properties: { name: { type: 'string' } }, required: ['name'] },
  },
  { name: 'plugin_market', description: 'List plugins from TRHA_PLUGIN_MARKET (URL or JSON file)', parameters: { type: 'object', properties: {}, required: [] } },
  {
    name: 'stagehand_navigate',
    description: 'Open a URL and return rendered text (alias of browser_navigate)',
    parameters: { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] },
  },
  {
    name: 'stagehand_extract',
    description: 'Extract page text or one selector (alias of browser_extract)',
    parameters: { type: 'object', properties: { selector: { type: 'string' } }, required: [] },
  },
  {
    name: 'stagehand_screenshot',
    description: 'Screenshot the page (alias of browser_screenshot)',
    parameters: { type: 'object', properties: { path: { type: 'string' } }, required: [] },
  },
  { name: 'stagehand_tabs', description: 'Report the current tab', parameters: { type: 'object', properties: {}, required: [] } },
  { name: 'stagehand_observe', description: 'List interactive elements on the page', parameters: { type: 'object', properties: {}, required: [] } },
  {
    name: 'stagehand_act',
    description: 'Act on the page: click | type a selector',
    parameters: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['click', 'type'] },
        selector: { type: 'string' },
        value: { type: 'string' },
        url: { type: 'string' },
      },
      required: ['action', 'selector'],
    },
  },
  {
    name: 'ralph',
    description: 'Ralph loop: fresh child agents, one round each, until DONE/BLOCKED',
    parameters: {
      type: 'object',
      properties: { objective: { type: 'string' }, rounds: { type: 'number' } },
      required: ['objective'],
    },
  },
  {
    name: 'append_file',
    description: 'Append text to a file inside the workspace (creates if missing)',
    parameters: {
      type: 'object',
      properties: { path: { type: 'string' }, content: { type: 'string' } },
      required: ['path', 'content'],
    },
  },
];

/** Flat model-facing spec (name/description/parameters at the top level,
 * matching the bridge wire format). */
export interface ToolSpec {
  name: string;
  description: string;
  parameters: ToolDefinition['parameters'];
}

export function toToolSpecs(defs: ToolDefinition[] = toolCatalog): ToolSpec[] {
  return defs.map(d => ({
    name: d.name,
    description: d.description,
    parameters: d.parameters,
  }));
}

/** Look a tool definition up by name (for execute-side validation). */
export function findTool(name: string, defs: ToolDefinition[] = toolCatalog): ToolDefinition | undefined {
  return defs.find(d => d.name === name);
}

/** Older names kept working, mapped onto the canonical ones. */
export const TOOL_ALIASES: Record<string, string> = {
  read_file: 'read',
  write_file: 'write',
  write_to_file: 'write',
  edit_file: 'edit',
  apply_patch: 'edit',
  list_dir: 'glob',
  list_files: 'glob',
};

export function canonicalToolName(name: string): string {
  return TOOL_ALIASES[name] ?? name;
}
