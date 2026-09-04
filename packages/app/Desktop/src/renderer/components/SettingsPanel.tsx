import React from 'react';
import { useAppStore } from '../stores/appStore';

interface SettingsPanelProps {
  onClose: () => void;
}

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
        {/* Theme */}
        <div className="setting-group">
          <label>Theme</label>
          <select value={theme} onChange={(e) => setTheme(e.target.value as 'light' | 'dark')}>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </div>

        {/* Current Mode Details */}
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
                <span className={`feature ${mode.hasWebSearch ? 'on' : 'off'}`}>Web Search</span>
              </div>
              <div className="mode-stats">
                <span>{mode.tools.length} tools</span>
                <span>{(mode.contextSize / 1024).toFixed(0)}K context</span>
                <span>{mode.maxTokens} max tokens</span>
              </div>
              {mode.ptc.enabled && (
                <div className="mode-ptc">
                  <strong>PTC Language:</strong> {mode.ptc.language}
                  <p>{mode.ptc.description}</p>
                </div>
              )}
            </div>
          </div>
        )}

        {/* All Modes */}
        <div className="setting-group">
          <label>Available Modes</label>
          <div className="settings-models">
            {Object.entries(modes).map(([name, m]) => (
              <div key={name} className={`settings-model-item ${name === currentMode ? 'active' : ''}`}>
                <strong>{name}</strong>
                <span>{m.description}</span>
                <span className="model-ctx">{m.tools.length} tools</span>
              </div>
            ))}
          </div>
        </div>

        {/* Models */}
        <div className="setting-group">
          <label>Available Models</label>
          <div className="settings-models">
            {models.map((model) => (
              <div key={model.name} className="settings-model-item">
                <strong>{model.name}</strong>
                <span>{model.description}</span>
                <span className="model-ctx">{(model.contextSize / 1024).toFixed(0)}K ctx</span>
              </div>
            ))}
          </div>
        </div>

        {/* Connection */}
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
