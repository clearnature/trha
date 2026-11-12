import React, { useRef, useState } from 'react';
import { useAppStore } from '../stores/appStore';

function fmtTokens(n: number): string {
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  return String(n);
}

const MODE_LABELS: Record<string, string> = {
  'read-only': 'Read only',
  ask: 'Ask',
  auto: 'Auto',
  yolo: 'YOLO',
  plan: 'Plan',
};

const MODE_FALLBACK = ['read-only', 'ask', 'auto', 'yolo', 'plan'];

/**
 * Composer, structured like dsh's InputBar: root clearance → card
 * (text surface + control row) → ContextMeter.
 *
 * The control row carries the `conversation.input.*` occupants we can back
 * with the scheduler today: permission posture and model selection. Enter
 * submits, Shift+Enter inserts a newline, paste is forced to plain text.
 */
export function Composer() {
  const {
    currentSession, sendMessage, agentState, createSession,
    sessionInfo, modes, currentMode,
    permission, setPermission, currentModel, setCurrentModel, models,
  } = useAppStore();
  const ref = useRef<HTMLDivElement>(null);
  const [empty, setEmpty] = useState(true);
  const busy = agentState.status === 'processing';
  const ctxSize = modes[currentMode]?.contextSize ?? 0;
  const used = sessionInfo?.promptTokens ?? 0;
  const cycle = permission?.cycle ?? MODE_FALLBACK;

  const send = async () => {
    const text = (ref.current?.innerText ?? '').trim();
    if (!text || busy) return;
    if (ref.current) {
      ref.current.innerHTML = '';
      setEmpty(true);
    }
    if (!currentSession) await createSession();
    await sendMessage(text);
  };

  const onKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      void send();
    }
  };

  const onInput = () => setEmpty(!(ref.current?.innerText ?? '').trim());

  const onPaste = (e: React.ClipboardEvent<HTMLDivElement>) => {
    e.preventDefault();
    const text = e.clipboardData.getData('text/plain');
    document.execCommand('insertText', false, text);
  };

  return (
    <div className="composer-root">
      <div className="composer-card">
        <div
          ref={ref}
          className="composer-input"
          contentEditable={!busy}
          role="textbox"
          aria-multiline="true"
          aria-label="Message"
          data-placeholder="Type a message… (Enter to send, Shift+Enter for newline)"
          onInput={onInput}
          onKeyDown={onKeyDown}
          onPaste={onPaste}
          suppressContentEditableWarning
        />
        <div className="composer-bar">
          <div className="composer-controls">
            <select
              className="composer-select"
              title="Permission mode"
              value={permission?.mode ?? 'read-only'}
              onChange={(e) => void setPermission(e.target.value)}
              disabled={!currentSession || !permission}
            >
              {cycle.map((mode) => (
                <option key={mode} value={mode}>{MODE_LABELS[mode] ?? mode}</option>
              ))}
            </select>
            <select
              className="composer-select"
              title="Model"
              value={currentModel}
              onChange={(e) => setCurrentModel(e.target.value)}
              disabled={models.length === 0}
            >
              {models.length === 0 && <option value="">—</option>}
              {models.map((m) => (
                <option key={m.name} value={m.name}>{m.name}</option>
              ))}
            </select>
            {ctxSize > 0 && (
              <span className="context-meter">{fmtTokens(used)} / {fmtTokens(ctxSize)}</span>
            )}
          </div>
          <button className="send-btn" onClick={send} disabled={busy || empty}>
            {busy ? '…' : 'Send'}
          </button>
        </div>
      </div>
    </div>
  );
}
