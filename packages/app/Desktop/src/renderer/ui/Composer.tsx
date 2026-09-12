// Composer: the message input + send button.  Enter sends, Shift+Enter adds
// a newline; disabled while the session is busy or the input is empty.

import { useState } from 'react';
import { useSession, useSessionStore } from './SessionContext.js';
import { useT } from './PrefsContext.js';

export function Composer() {
  const currentId = useSession(s => s.currentId);
  const busy = useSession(s => s.busy);
  const store = useSessionStore();
  const t = useT();
  const [input, setInput] = useState('');

  const send = async () => {
    const text = input.trim();
    if (!text || busy) return;
    let sid = currentId;
    if (!sid) sid = await store.getState().create();
    if (!sid) return;
    setInput('');
    await store.getState().send(text);
  };

  return (
    <div className="input-container">
      <textarea
        aria-label="message"
        value={input}
        onChange={e => setInput(e.target.value)}
        onKeyDown={e => {
          if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void send(); }
        }}
        placeholder={t('composer.placeholder')}
        rows={3}
        disabled={busy}
      />
      <button type="button" onClick={() => void send()} disabled={!input.trim() || busy}>
        {t('composer.send')}
      </button>
    </div>
  );
}

export default Composer;
