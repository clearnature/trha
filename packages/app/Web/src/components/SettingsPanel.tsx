import React from 'react';
import { useAppStore } from '../stores/appStore';

interface SettingsPanelProps { onClose: () => void; }

export function SettingsPanel({ onClose }: SettingsPanelProps) {
  const { theme, setTheme, models, modes, currentMode } = useAppStore();
  const mode = modes[currentMode];

  return (
    <div className="settings-panel">
      <div className="settings-header">
        <h3>Settings</h3>
        <button onClick={onClose} className="close-btn">×</button>
      </div>
      <div className="settings-content">
        <div className="setting-group">
          <label>Theme</label>
          <select value={theme} onChange={(e) => setTheme(e.target.value as 'light' | 'dark')}>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </div>

        {mode && (
          <div className="setting-group">
            <label>Current Mode: {currentMode}</label>
            <div className="mode-details">
              <p className="mode-desc">{mode.description}</p>
              <div className="mode-features">
                <span className={`feature ${mode.persona.enabled ? 'on' : 'off'}`}>Persona</span>
                <span className={`feature ${mode.compaction.enabled ? 'on' : 'off'}`}>Compaction</span>
                <span className={`feature ${mode.delegation.enabled ? 'on' : 'off'}`}>Delegation</span>
                <span className={`feature ${mode.ptc.enabled ? 'on' : 'off'}`}>PTC/run_code</span>
                <span className={`feature ${mode.hasPlan ? 'on' : 'off'}`}>Plan</span>
                <span className={`feature ${mode.hasTodo ? 'on' : 'off'}`}>Todo</span>
              </div>
              <div className="mode-stats">
                <span>{mode.tools.length} tools</span>
                <span>{(mode.contextSize / 1024).toFixed(0)}K context</span>
                <span>{mode.maxTokens} max tokens</span>
              </div>
            </div>
          </div>
        )}

        <div className="setting-group">
          <label>Available Models</label>
          <div className="settings-models">
            {models.map((m) => (
              <div key={m.name} className="settings-model-item">
                <strong>{m.name}</strong>
                <span>{m.description}</span>
                <span className="model-ctx">{(m.contextSize / 1024).toFixed(0)}K ctx</span>
              </div>
            ))}
          </div>
        </div>

        <div className="setting-group">
          <label>Connection</label>
          <div className="settings-info">
            <span>Scheduler: localhost:3456</span>
            <span>Backend: Haskell core (Warp + servant)</span>
          </div>
        </div>
      </div>
    </div>
  );
}
