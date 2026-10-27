import React from 'react';
import { useAppStore } from '../stores/appStore';
import type { TodoItem } from '../types';
import { agentRows } from '../layout/agents';

interface SidebarProps {
  collapsed: boolean;
  onToggle: () => void;
  onSettingsClick: () => void;
}

function fmtTokens(n: number): string {
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  return String(n);
}

function todoMark(status: TodoItem['status']): string {
  return status === 'completed' ? '✓' : status === 'in_progress' ? '▶' : '○';
}

/** Left column: brand/actions, sessions, then live context/todo/files/agents. */
export function Sidebar({ collapsed, onToggle, onSettingsClick }: SidebarProps) {
  const {
    sessions, currentSession, setCurrentSession, createSession,
    modes, currentMode, setMode,
    sessionInfo, agents, files, openFile,
  } = useAppStore();

  if (collapsed) {
    return (
      <nav className="rail" aria-label="Sidebar">
        <button className="rail-btn" title="Expand sidebar" onClick={onToggle}>›</button>
        <button className="rail-btn" title="New session" onClick={createSession}>+</button>
        <div className="rail-spacer" />
        <button className="rail-btn" title="Settings" onClick={onSettingsClick}>⚙</button>
      </nav>
    );
  }

  const cacheTotal = sessionInfo ? sessionInfo.cacheHit + sessionInfo.cacheMiss : 0;
  const cacheRate = cacheTotal > 0
    ? `${((sessionInfo!.cacheHit / cacheTotal) * 100).toFixed(1)}%`
    : '';
  const todos = sessionInfo?.todos ?? [];
  const agentTree = agentRows(agents, currentSession?.id);

  return (
    <aside className="sidebar">
      <header className="sidebar-header">
        <span className="brand">trha</span>
        <div className="sidebar-actions">
          <button className="ghost-btn" title="Collapse sidebar" onClick={onToggle}>‹</button>
        </div>
      </header>

      <button className="new-session" onClick={createSession}>
        <span className="new-session-icon">＋</span>
        <span>New session</span>
      </button>

      <div className="sidebar-scroll">
        <div className="sidebar-section sessions">
          <div className="section-label">Sessions</div>
          <div className="sessions-list">
            {sessions.map((session) => (
              <button
                key={session.id}
                className={`session-item ${currentSession?.id === session.id ? 'active' : ''}`}
                onClick={() => setCurrentSession(session)}
              >
                <span className="session-title">{session.title}</span>
                <span className="session-date">{session.messages.length}</span>
              </button>
            ))}
            {sessions.length === 0 && <div className="session-empty">No sessions yet</div>}
          </div>
        </div>

        {sessionInfo && (
          <div className="sidebar-section">
            <div className="section-label">Context</div>
            <div className="meta-row">
              {fmtTokens(sessionInfo.promptTokens)}
              {cacheRate && <span className="muted"> · cache {cacheRate}</span>}
            </div>
            {sessionInfo.goal && (
              <div className="meta-row muted ellipsis">goal: {sessionInfo.goal}</div>
            )}
            {sessionInfo.cwd && (
              <div className="meta-row muted ellipsis">{sessionInfo.cwd}</div>
            )}
          </div>
        )}

        {todos.length > 0 && (
          <div className="sidebar-section">
            <div className="section-label">Todo</div>
            {todos.slice(0, 8).map((t) => (
              <div key={t.id} className="todo-row">
                <span className={`todo-mark ${t.status}`}>{todoMark(t.status)}</span>
                <span className="ellipsis">{t.text}</span>
              </div>
            ))}
          </div>
        )}

        {files.length > 0 && (
          <div className="sidebar-section">
            <div className="section-label">Files</div>
            {files.map((f) => (
              <div
                key={f.path}
                className={`file-row ${f.dir ? 'dir' : 'file'}`}
                onClick={() => { if (!f.dir) void openFile(f.path); }}
                role={f.dir ? undefined : 'button'}
                tabIndex={f.dir ? undefined : 0}
                onKeyDown={(e) => { if (!f.dir && e.key === 'Enter') void openFile(f.path); }}
              >
                {f.dir ? '▸ ' : ''}{f.path}
              </div>
            ))}
          </div>
        )}

        {agentTree.length > 1 && (
          <div className="sidebar-section">
            <div className="section-label">Agents</div>
            {agentTree.map((a) => (
              <div
                key={a.id}
                className={`agent-row ${a.current ? 'current' : ''}`}
                style={{ paddingLeft: 4 + a.depth * 10 }}
              >
                {a.current ? '● ' : '· '}{a.id}
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="sidebar-section">
        <div className="section-label">Mode</div>
        <select
          className="mode-selector"
          value={currentMode}
          onChange={(e) => setMode(e.target.value)}
        >
          {Object.entries(modes).map(([name, mode]) => (
            <option key={name} value={name}>{name} — {mode.description}</option>
          ))}
        </select>
      </div>

      <footer className="sidebar-footer">
        <button className="ghost-btn" title="Settings" onClick={onSettingsClick}>⚙</button>
      </footer>
    </aside>
  );
}
