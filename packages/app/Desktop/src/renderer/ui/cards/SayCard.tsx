// Assistant message card: light markdown rendering plus a streaming cursor
// while the reply is still arriving.

import { Markdown } from '../markdown.js';

export interface SayCardProps {
  text: string;
  /** Show a trailing cursor while the assistant is still streaming. */
  streaming?: boolean;
}

export function SayCard({ text, streaming }: SayCardProps) {
  return (
    <div className="message assistant" data-card="say" data-streaming={streaming ? 'true' : undefined}>
      <div className="message-header"><span className="message-role">assistant</span></div>
      <div className="message-content">
        <Markdown text={text} />
        {streaming && <span className="md-cursor" aria-hidden="true">▌</span>}
      </div>
    </div>
  );
}

export default SayCard;
