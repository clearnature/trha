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
    description: 'Replace the session todo list (the plan you are working through)',
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
