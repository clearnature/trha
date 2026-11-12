import React, { useEffect, useRef, useState } from 'react';
import { useAppStore } from '../stores/appStore';
import { Composer } from './Composer';
import { Markdown } from './Markdown';
import { groupTurns } from '../layout/turns';
import { ToolCard } from './ToolCard';

function fmtTokens(n: number): string {
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  return String(n);
}

/**
 * Centre column (dsh ChatView): a centred transcript column over the shared
 * chat width, turn-grouped rows, stats pills on the last assistant row, and a
 * running indicator while a turn is in flight. Auto-scroll only follows the
 * tail when the user is already at the bottom.
 */
export function ChatView() {
  const { currentSession, agentState, createSession, sessionInfo, toolEvents, reasoning } = useAppStore();
  const endRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const [following, setFollowing] = useState(true);
  const busy = agentState.status === 'processing';

  const onScroll = () => {
    const el = listRef.current;
    if (!el) return;
    setFollowing(el.scrollTop + el.clientHeight >= el.scrollHeight - 24);
  };

  useEffect(() => {
    if (following) endRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [currentSession?.messages, following]);

  const turns = groupTurns(currentSession?.messages ?? []);
  const cacheTotal = sessionInfo ? sessionInfo.cacheHit + sessionInfo.cacheMiss : 0;
  const cacheRate = cacheTotal > 0
    ? `${((sessionInfo!.cacheHit / cacheTotal) * 100).toFixed(1)}%`
    : '';

  return (
    <div className="chat">
      <header className="chat-header">
        <div className="chat-title">
          <h1>{currentSession?.title ?? 'New session'}</h1>
          <span className={`agent-status ${agentState.status}`}>
            {busy ? 'thinking…'
              : agentState.status === 'error' ? `error: ${agentState.message ?? ''}`
              : 'ready'}
          </span>
        </div>
      </header>

      <div className="messages" ref={listRef} onScroll={onScroll} data-following={following || undefined}>
        {!currentSession && (
          <div className="chat-empty">
            <h2>Welcome to trha</h2>
            <p>Type a message below to start a new session.</p>
            <button className="new-session" onClick={createSession}>
              <span className="new-session-icon">＋</span>
              <span>New session</span>
            </button>
          </div>
        )}

        {turns.map((turn) => {
          const last = turn.messages[turn.messages.length - 1];
          return (
            <section key={turn.index} className="turn">
              {turn.messages.map((msg, i) => (
                <article key={i} className={`message ${msg.role}`}>
                  <div className="message-role">{msg.role}</div>
                  <div className="message-content">
                    {msg.role === 'assistant'
                      ? <Markdown text={msg.content} />
                      : msg.content}
                  </div>
                  {msg === last && msg.role === 'assistant' && (
                    <div className="stats-pills">
                      {sessionInfo && <span>{fmtTokens(sessionInfo.promptTokens)} ctx</span>}
                      {cacheRate && <span>cache {cacheRate}</span>}
                      {sessionInfo?.todos.length ? <span>{sessionInfo.todos.length} todo</span> : null}
                    </div>
                  )}
                </article>
              ))}
            </section>
          );
        })}

        {currentSession && currentSession.messages.length === 0 && (
          <div className="messages-empty">Send a message to start the conversation.</div>
        )}

        {toolEvents.length > 0 && (
          <div className="tool-stack">
            {toolEvents.map((event, i) => <ToolCard key={i} event={event} />)}
          </div>
        )}

        {reasoning && (
          <details className="reasoning-row">
            <summary>reasoning</summary>
            <pre>{reasoning}</pre>
          </details>
        )}

        {busy && (
          <div className="running-status">
            <span className="dot" />
            <span>thinking…</span>
          </div>
        )}

        <div ref={endRef} />
      </div>

      <Composer />
    </div>
  );
}
