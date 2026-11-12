// Sidebar: session list with create/select/delete, plus the mode selector
// and read-only catalog panels (tools/models).  All state flows through the
// session store (which is port-backed); no direct fetch here.

import { useSession, useSessionStore } from './SessionContext.js';
import { useT } from './PrefsContext.js';

export interface SidebarProps {
  onSettingsClick?: () => void;
}

export function Sidebar({ onSettingsClick }: SidebarProps) {
  const sessions = useSession(s => s.sessions);
  const currentId = useSession(s => s.currentId);
  const modes = useSession(s => s.modes);
  const models = useSession(s => s.models);
  const tools = useSession(s => s.tools);
  const selectedMode = useSession(s => s.selectedMode);
  const store = useSessionStore();
  const t = useT();

  return (
    <aside className="sidebar">
      <div className="sidebar-header">
        <h2>trha</h2>
        <button
          type="button"
          className="new-session-btn"
          onClick={() => void store.getState().create()}
        >
          {t('app.newSession')}
        </button>
      </div>

      <div className="sessions-list">
        {sessions.map(session => (
          <div
            key={session.id}
            className={`session-item ${currentId === session.id ? 'active' : ''}`}
            role="button"
            tabIndex={0}
            onClick={() => void store.getState().select(session.id)}
            onKeyDown={e => { if (e.key === 'Enter') void store.getState().select(session.id); }}
          >
            <span className="session-title" title={session.id}>
              {session.mode} · {session.id.slice(0, 8)}
            </span>
            <span className="session-date">{t('list.messages', { count: session.messages.length })}</span>
            <button
              type="button"
              className="session-delete"
              aria-label={`delete ${session.id}`}
              onClick={e => { e.stopPropagation(); void store.getState().remove(session.id); }}
            >
              ✕
            </button>
          </div>
        ))}
        {sessions.length === 0 && <div className="session-empty">{t('list.noSessions')}</div>}
      </div>

      <div className="sidebar-section">
        <h3>Mode</h3>
        <select
          className="mode-selector"
          aria-label="mode"
          value={selectedMode}
          onChange={e => store.getState().setMode(e.target.value)}
        >
          {Object.keys(modes).map(name => (
            <option key={name} value={name}>{name}</option>
          ))}
          {Object.keys(modes).length === 0 && <option value={selectedMode}>{selectedMode}</option>}
        </select>
        {modes[selectedMode] && (
          <div className="mode-info">
            {modes[selectedMode].hasRunCode && <span className="mode-badge">run_code</span>}
            <span className="mode-tools">{modes[selectedMode].tools.length} tools</span>
          </div>
        )}
      </div>

      <div className="sidebar-section">
        <h3>Tools ({tools.length})</h3>
        <div className="tools-list">
          {tools.map(tool => (
            <div key={tool.name} className="tool-item" title={tool.description}>🔧 {tool.name}</div>
          ))}
        </div>
      </div>

      <div className="sidebar-section">
        <h3>Models ({models.length})</h3>
        <div className="models-list">
          {models.map(model => (
            <div key={model.name} className="model-item" title={model.description}>
              🤖 {model.name}
              <span className="model-ctx">{(model.contextSize / 1024).toFixed(0)}K</span>
            </div>
          ))}
        </div>
      </div>

      <div className="sidebar-footer">
        <button type="button" className="settings-btn" onClick={onSettingsClick}>⚙️ Settings</button>
      </div>
    </aside>
  );
}

export default Sidebar;
