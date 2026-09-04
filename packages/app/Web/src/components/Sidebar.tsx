import React from 'react';
import { useAppStore } from '../stores/appStore';

interface SidebarProps {
  onSettingsClick: () => void;
}

export function Sidebar({ onSettingsClick }: SidebarProps) {
  const { sessions, currentSession, setCurrentSession, createSession, tools, models, modes, currentMode, setMode } = useAppStore();

  return (
    <aside className="sidebar">
      <div className="sidebar-header">
        <h2>gh-harness</h2>
        <button onClick={createSession} className="new-session-btn">+ New Session</button>
      </div>

      <div className="sessions-list">
        {sessions.map((session) => (
          <div
            key={session.id}
            className={`session-item ${currentSession?.id === session.id ? 'active' : ''}`}
            onClick={() => setCurrentSession(session)}
          >
            <span className="session-title">{session.title}</span>
            <span className="session-date">{session.messages.length} messages</span>
          </div>
        ))}
        {sessions.length === 0 && <div className="session-empty">No sessions yet</div>}
      </div>

      {/* Mode selector */}
      <div className="sidebar-section">
        <h3>Mode</h3>
        <select className="mode-selector" value={currentMode} onChange={(e) => setMode(e.target.value)}>
          {Object.entries(modes).map(([name, mode]) => (
            <option key={name} value={name}>{name} — {mode.description}</option>
          ))}
        </select>
        {modes[currentMode] && (
          <div className="mode-info">
            {modes[currentMode].ptc.enabled && <span className="mode-badge">run_code</span>}
            {modes[currentMode].persona.enabled && <span className="mode-badge">persona</span>}
            <span className="mode-tools">{modes[currentMode].tools.length} tools</span>
          </div>
        )}
      </div>

      {/* Tools panel */}
      <div className="sidebar-section">
        <h3>Tools ({tools.length})</h3>
        <div className="tools-list">
          {tools.map((tool) => (
            <div key={tool.name} className="tool-item" title={tool.description}>🔧 {tool.name}</div>
          ))}
        </div>
      </div>

      {/* Models panel */}
      <div className="sidebar-section">
        <h3>Models ({models.length})</h3>
        <div className="models-list">
          {models.map((model) => (
            <div key={model.name} className="model-item" title={model.description}>
              🤖 {model.name}
              <span className="model-ctx">{(model.contextSize / 1024).toFixed(0)}K</span>
            </div>
          ))}
        </div>
      </div>

      <div className="sidebar-footer">
        <button onClick={onSettingsClick} className="settings-btn">⚙️ Settings</button>
      </div>
    </aside>
  );
}
