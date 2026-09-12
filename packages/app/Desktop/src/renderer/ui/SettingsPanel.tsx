// Settings panel: local preferences (theme / language / font size) plus a
// read-only kernel surface (mode detail, modes, models, version/pin).

import { usePrefs } from './PrefsContext.js';
import { FONT_SIZE_RANGE, type Lang, type Theme } from '../state/prefs.js';
import { LANGS } from './i18n.js';
import { useSession, useSessionStore } from './SessionContext.js';
import { ProvidersPanel } from './ProvidersPanel.js';

export interface SettingsPanelProps {
  onClose: () => void;
}

export function SettingsPanel({ onClose }: SettingsPanelProps) {
  const { prefs, setPrefs, t } = usePrefs();
  const modes = useSession(s => s.modes);
  const models = useSession(s => s.models);
  const currentMode = useSession(s => s.selectedMode);
  const version = useSession(s => s.version);
  const store = useSessionStore();
  const mode = modes[currentMode];

  return (
    <div className="settings-panel" role="dialog" aria-label={t('settings.title')}>
      <div className="settings-header">
        <h3>{t('settings.title')}</h3>
        <button onClick={onClose} className="close-btn" aria-label="close">×</button>
      </div>

      <div className="settings-content">
        <div className="setting-group">
          <label htmlFor="pref-theme">{t('settings.theme')}</label>
          <select
            id="pref-theme"
            value={prefs.theme}
            onChange={e => setPrefs({ theme: e.target.value as Theme })}
          >
            <option value="light">{t('settings.theme.light')}</option>
            <option value="dark">{t('settings.theme.dark')}</option>
          </select>
        </div>

        <div className="setting-group">
          <label htmlFor="pref-lang">{t('settings.language')}</label>
          <select
            id="pref-lang"
            value={prefs.lang}
            onChange={e => setPrefs({ lang: e.target.value as Lang })}
          >
            {LANGS.map(l => <option key={l} value={l}>{l}</option>)}
          </select>
        </div>

        <div className="setting-group">
          <label htmlFor="pref-font">{t('settings.fontSize')}</label>
          <input
            id="pref-font"
            type="range"
            min={FONT_SIZE_RANGE.min}
            max={FONT_SIZE_RANGE.max}
            value={prefs.fontSize}
            onChange={e => setPrefs({ fontSize: Number(e.target.value) })}
          />
          <span className="pref-value">{prefs.fontSize}px</span>
        </div>

        {mode && (
          <div className="setting-group">
            <label>{t('settings.currentMode', { mode: currentMode })}</label>
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
            </div>
          </div>
        )}

        <div className="setting-group">
          <label>{t('settings.modes')}</label>
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

        <div className="setting-group">
          <label>{t('settings.models')}</label>
          <div className="settings-models">
            {models.map(model => (
              <div key={model.name} className="settings-model-item">
                <strong>{model.name}</strong>
                <span>{model.description}</span>
                <span className="model-ctx">{(model.contextSize / 1024).toFixed(0)}K ctx</span>
              </div>
            ))}
          </div>
        </div>

        <div className="setting-group">
          <ProvidersPanel port={store.getState().port} />
        </div>

        <div className="setting-group">
          <label>{t('settings.connection')}</label>
          <div className="settings-info">
            <span>{t('settings.version')}: {version ? version.current : '—'}</span>
            <span>{t('settings.pinned')}: {version?.pinned ?? '—'}</span>
          </div>
        </div>
      </div>
    </div>
  );
}

export default SettingsPanel;
