// Tool call card: name, arguments, status and duration, with a collapsible
// detail section (arguments + error output).

import { useState } from 'react';
import type { PortToolEvent } from '../../port/types.js';

const STATUS_ICON: Record<PortToolEvent['status'], string> = {
  running: '⏳',
  succeeded: '✅',
  failed: '❌',
};

export interface ToolCardProps {
  tool: PortToolEvent;
}

export function ToolCard({ tool }: ToolCardProps) {
  const [open, setOpen] = useState(false);
  const hasDetail = tool.args.length > 0 || !!tool.error;

  return (
    <div className={`tool-card ${tool.status}`} data-card="tool" data-status={tool.status}>
      <button
        type="button"
        className="tool-card-header"
        onClick={() => hasDetail && setOpen(o => !o)}
        aria-expanded={open}
        disabled={!hasDetail}
      >
        <span className="tool-icon">{STATUS_ICON[tool.status]}</span>
        <span className="tool-name">{tool.name}</span>
        {tool.durationMs !== undefined && <span className="tool-duration">{tool.durationMs}ms</span>}
        {hasDetail && <span className="tool-toggle">{open ? '▾' : '▸'}</span>}
      </button>
      {open && hasDetail && (
        <div className="tool-detail">
          {tool.args.length > 0 && (
            <pre className="tool-args">{tool.args.join('\n')}</pre>
          )}
          {tool.error && <div className="tool-error">{tool.error}</div>}
        </div>
      )}
    </div>
  );
}

export default ToolCard;
