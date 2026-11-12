// Message list: renders the session's UI message stream as cards, plus the
// empty/welcome states.  Reads the session store.

import { UserCard } from './cards/UserCard.js';
import { SayCard } from './cards/SayCard.js';
import { ToolCard } from './cards/ToolCard.js';
import { NoticeCard } from './cards/NoticeCard.js';
import { useSession, useSessionStore } from './SessionContext.js';
import { useT } from './PrefsContext.js';

export function MessageList() {
  const messages = useSession(s => s.uiMessages);
  const streamText = useSession(s => s.streamText);
  const currentId = useSession(s => s.currentId);
  const busy = useSession(s => s.busy);
  const store = useSessionStore();
  const t = useT();

  if (!currentId) {
    return (
      <div className="chat-empty">
        <h2>{t('app.welcome.title')}</h2>
        <p>{t('app.welcome.body')}</p>
        <button type="button" className="new-session-btn" onClick={() => void store.getState().create()}>
          {t('app.newSession')}
        </button>
      </div>
    );
  }

  return (
    <div className="messages-container">
      {messages.map((m, i) => {
        const isLast = i === messages.length - 1;
        switch (m.kind) {
          case 'user': return <UserCard key={i} text={m.text} />;
          case 'assistant': return <SayCard key={i} text={m.text} streaming={busy && isLast} />;
          case 'tool': return <ToolCard key={i} tool={m.tool} />;
          case 'notice': return <NoticeCard key={i} text={m.text} tone="error" />;
          default: return null;
        }
      })}
      {/* A3: the answer as it arrives, before step() returns it in full. */}
      {streamText !== '' && <SayCard text={streamText} streaming />}
      {messages.length === 0 && (
        <div className="messages-empty">{t('list.empty')}</div>
      )}
    </div>
  );
}

export default MessageList;
