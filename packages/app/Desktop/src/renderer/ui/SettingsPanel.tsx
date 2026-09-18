// 设置中心（全窗容器）：左栏 8 组导航 + 右栏 tab 面板派发。
// 对齐 Reasonix 三维架构（11 完整功能区 / 8 导航组 / 21 tab 全集）——
// 见 docs/plans/reasonix-settings-architecture-analysis.md。
// 已接线：general(prefs) → appearance(外观) ⊂ general 功能区合并；models → LlmSettingsPanel；
//         providers → ProvidersPanel；其余 → ScaffoldPanel（预留接口，诚实标注规划中）。

import { useState } from 'react';
import { usePrefs } from './PrefsContext.js';
import { FONT_SIZE_RANGE, type Lang, type Theme } from '../state/prefs.js';
import { LANGS } from './i18n.js';
import { useSession, useSessionStore } from './SessionContext.js';
import { ProvidersPanel } from './ProvidersPanel.js';
import { SettingsNavigation } from './SettingsNavigation.js';
import { LlmSettingsPanel } from './LlmSettingsPanel.js';
import { GeneralSettingsPanel } from './GeneralSettingsPanel.js';
import { ModelPreferencesPanel } from './ModelPreferencesPanel.js';
import { McpPanel } from './McpPanel.js';
import { SkillsPanel } from './SkillsPanel.js';
import { SubagentsPanel } from './SubagentsPanel.js';
import { PluginsPanel } from './PluginsPanel.js';
import { MemoryPanel } from './MemoryPanel.js';
import { HooksPanel } from './HooksPanel.js';
import { DiagnosticsPanel } from './DiagnosticsPanel.js';
import { PermissionsPanel } from './PermissionsPanel.js';
import { SandboxPanel } from './SandboxPanel.js';
import { BrowserPanel } from './BrowserPanel.js';
import { AppearancePanel } from './AppearancePanel.js';
import { StoragePanel } from './StoragePanel.js';
import { UpdatesPanel } from './UpdatesPanel.js';
import { NetworkPanel } from './NetworkPanel.js';
import { ModelStatsPanel } from './ModelStatsPanel.js';
import { BotsPanel } from './BotsPanel.js';
import { RemotePanel as RemoteSSHPanel } from './RemotePanel.js';
import { ShortcutsPanel } from './ShortcutsPanel.js';
import { ScaffoldPanel } from './ScaffoldPanel.js';
import { ALL_SETTINGS_TABS, SETTINGS_GROUPS } from '../state/settingsTypes.js';

export interface SettingsPanelProps {
  onClose: () => void;
}

export function SettingsPanel({ onClose }: SettingsPanelProps) {
  const { prefs, setPrefs, t } = usePrefs();
  const mode = useSession(s => s.modes[s.selectedMode]);
  const version = useSession(s => s.version);
  const store = useSessionStore();
  const [tab, setTab] = useState<string>('general');

  // 当前 tab 定义（从 8 组里找）
  const allTabs = SETTINGS_GROUPS.flatMap(g => g.tabs);
  const tabDef = allTabs.find(x => x.id === tab) ?? allTabs[0];

  return (
    <div className="settings-center" role="dialog" aria-label={t('settings.title')}>
      <div className="settings-header">
        <h3>{t('settings.title')}</h3>
        <button onClick={onClose} className="close-btn" aria-label="close">×</button>
      </div>

      <div className="settings-center-body">
        <SettingsNavigation activeTab={tab} onSelect={setTab} t={t} />

        <div className="settings-center-content" data-tab={tab}>
          {tab === 'general' && <GeneralSettingsPanel t={t} />}

          {tab === 'appearance' && <AppearancePanel t={t} />}

          {tab === 'storage' && <StoragePanel t={t} />}

          {tab === 'updates' && <UpdatesPanel t={t} />}

          {tab === 'model-stats' && <ModelStatsPanel t={t} />}
          {tab === 'bots' && <BotsPanel t={t} />}
          {tab === 'remote' && <RemoteSSHPanel t={t} />}
          {tab === 'network' && <NetworkPanel t={t} />}
          {tab === 'shortcuts' && <ShortcutsPanel t={t} />}

          {tabDef && !['general', 'appearance', 'models', 'providers'].includes(tab) && (
            <ScaffoldPanel
              tabId={tab}
              titleKey={tabDef.labelKey}
              descriptionKey={`settings.scaffold.${tab}.desc`}
              plannedInterface={tabDef.plannedInterface}
              statusKey={tabDef.status === 'scaffold' ? 'settings.status.scaffold' : 'settings.status.partial'}
              t={t}
            />
          )}

          {tab === 'about' && (
            <div className="settings-pagebody">
              <div className="settings-page-title">
                <h3>{t('settings.about.title')}</h3>
              </div>
              <div className="setting-group">
                <label>{t('settings.connection')}</label>
                <div className="settings-info">
                  <span>{t('settings.version')}: {version ? version.current : '—'}</span>
                  <span>{t('settings.pinned')}: {version?.pinned ?? '—'}</span>
                  {mode && <span>{t('settings.currentMode', { mode: store.getState().selectedMode })}</span>}
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

export default SettingsPanel;