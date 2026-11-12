import React, { useState } from 'react';
import type { ToolEvent } from '../layout/sse';

/** One tool call row (dsh TurnProcessNodeView: status glyph, tool name, args,
 * duration; expanding reveals the tail preview or the error). */
export function ToolCard({ event }: { event: ToolEvent }) {
  const [open, setOpen] = useState(false);
  const glyph = event.status === 'running' ? '•' : event.status === 'succeeded' ? '✓' : '✗';
  const hasBody = Boolean(event.output) || Boolean(event.error);

  return (
    <div className={`tool-card ${event.status}`}>
      <button
        type="button"
        className="tool-head"
        onClick={() => hasBody && setOpen(!open)}
        aria-expanded={hasBody ? open : undefined}
      >
        <span className="tool-status">{glyph}</span>
        <span className="tool-name">{event.name}</span>
        {event.args && event.args.length > 0 && (
          <span className="tool-args">{event.args.join(' ')}</span>
        )}
        {typeof event.durationMs === 'number' && (
          <span className="tool-time">{event.durationMs}ms</span>
        )}
      </button>
      {open && event.output && <pre className="tool-output">{event.output}</pre>}
      {open && event.error && <div className="tool-error">{event.error}</div>}
    </div>
  );
}
