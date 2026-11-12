// 外观面板（应用 → 外观）——形态对齐 Reasonix Appearance 页：
//   当前外观：主题包（石墨）+ 浏览主题/创建副本
//   明暗模式：自动/浅色/深色（接线 prefs.theme）
//   终端主题 / 会话区域宽度 / 界面字号（档位）/ 界面字体 / 等宽字体 / 详细排版 / 显示缩放
// 接线状态：明暗模式、界面字号档位、显示缩放 本地可用；主题包/字体/排版预留。

import { useState } from 'react';
import { usePrefs } from './PrefsContext.js';
import type { Theme } from '../state/prefs.js';

export interface AppearancePanelProps {
  t: (key: string) => string;
}

// 字号档位 → px（接线 prefs.fontSize）
const FONT_SIZES: Record<string, number> = { small: 12, default: 14, large: 16, xl: 18, xxl: 20 };

export function AppearancePanel({ t }: AppearancePanelProps) {
  const { prefs, setPrefs } = usePrefs();
  const [terminalTheme, setTerminalTheme] = useState('follow-app');
  const [width, setWidth] = useState('standard');
  const sizeKey = Object.entries(FONT_SIZES).find(([, px]) => px === prefs.fontSize)?.[0] ?? 'default';
  const setSizeKey = (k: string) => setPrefs({ fontSize: FONT_SIZES[k] ?? 14 });
  const [zoom, setZoom] = useState(100);

  return (
    <div className="settings-pagebody">
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.appearance.currentTheme')}</h4>
        <div className="appearance-theme-row">
          <strong>{t('settings.appearance.graphite')}</strong>
          <span className="diag-status diag-status--passed">{t('settings.appearance.inUse')}</span>
          <div className="hooks-actions">
            <button type="button" className="btn" disabled title={t('settings.appearance.browsePlanned')}>{t('settings.appearance.browseThemes')}</button>
            <button type="button" className="btn" disabled title={t('settings.appearance.duplicatePlanned')}>{t('settings.appearance.duplicate')}</button>
          </div>
        </div>
      </section>

      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.appearance.appearanceTitle')}</h4>

        <div className="setting-group">
          <label htmlFor="pref-theme">{t('settings.appearance.themeMode')}</label>
          <select id="pref-theme" value={prefs.theme === 'dark' ? 'dark' : 'light'}
            onChange={e => setPrefs({ theme: e.target.value as Theme })}>
            <option value="light">{t('settings.appearance.light')}</option>
            <option value="dark">{t('settings.appearance.dark')}</option>
          </select>
          <span className="param-hint">{t('settings.appearance.themeModeHint')}（接线 prefs.theme）</span>
        </div>

        <div className="setting-group">
          <label>{t('settings.appearance.terminalTheme')}</label>
          <select value={terminalTheme} onChange={e => setTerminalTheme(e.target.value)}>
            <option value="follow-app">{t('settings.appearance.followApp')}</option>
            <option value="light">{t('settings.appearance.light')}</option>
            <option value="dark">{t('settings.appearance.dark')}</option>
          </select>
        </div>

        <div className="setting-group">
          <label>{t('settings.appearance.sessionWidth')}</label>
          <select value={width} onChange={e => setWidth(e.target.value)}>
            <option value="standard">{t('settings.appearance.widthStandard')}</option>
            <option value="full">{t('settings.appearance.widthFull')}</option>
          </select>
        </div>

        <div className="setting-group">
          <label htmlFor="pref-fontsize">{t('settings.appearance.fontSize')}</label>
          <select id="pref-fontsize" value={sizeKey} onChange={e => setSizeKey(e.target.value)}>
            <option value="small">{t('settings.appearance.fontSmall')}</option>
            <option value="default">{t('settings.appearance.fontDefault')}</option>
            <option value="large">{t('settings.appearance.fontLarge')}</option>
            <option value="xl">{t('settings.appearance.fontXl')}</option>
            <option value="xxl">{t('settings.appearance.fontXxl')}</option>
          </select>
        </div>

        <div className="setting-group">
          <label>{t('settings.appearance.interfaceFont')}</label>
          <select disabled title={t('settings.appearance.fontPlanned')}>
            <option>{t('settings.appearance.systemFont')}</option>
          </select>
        </div>

        <div className="setting-group">
          <label>{t('settings.appearance.monoFont')}</label>
          <select disabled title={t('settings.appearance.fontPlanned')}>
            <option>{t('settings.appearance.systemMono')}</option>
          </select>
        </div>

        <div className="hooks-actions">
          <button type="button" className="btn" disabled title={t('settings.appearance.typographyPlanned')}>
            {t('settings.appearance.typography')}
          </button>
        </div>
        <span className="param-hint"><code>typographySettings</code>（预留）</span>
      </section>

      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.appearance.zoomTitle')}</h4>
        <div className="zoom-row">
          <span>{zoom}%</span>
          <input type="range" min={50} max={200} step={10} value={zoom}
            onChange={e => setZoom(Number(e.target.value))} />
          <span>50% – 200%</span>
        </div>
      </section>

      <section className="settings-block">
        <button type="button" className="btn" disabled title={t('settings.appearance.resetPlanned')}>
          {t('settings.appearance.reset')}
        </button>
        <p className="param-hint">{t('settings.appearance.resetHint')}</p>
      </section>
    </div>
  );
}

export default AppearancePanel;