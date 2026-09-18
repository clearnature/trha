// 浏览器控制面板（安全与控制 → 浏览器控制）——形态对齐 Reasonix Browser 页：
//   状态行：已从 Default 导入 N 个 Cookie
//   基础设置：开启内置浏览器控制开关、导入 Chrome 登录状态、忽略证书校验
//   浏览器数据：清除内置浏览器缓存 / 清除全部浏览器数据（危险操作提示）
// 接线状态：开关本地可用；Cookie 导入/缓存清除经内核浏览器后端（预留）。

import { useState } from 'react';

export interface BrowserPanelProps {
  t: (key: string) => string;
}

export function BrowserPanel({ t }: BrowserPanelProps) {
  const [enabled, setEnabled] = useState(false);
  const [ignoreCert, setIgnoreCert] = useState(false);
  const [confirmClear, setConfirmClear] = useState(false);

  return (
    <div className="settings-pagebody">
      <p className="param-hint">{t('settings.browser.importStatus', { n: '0', skipped: '52' })}</p>

      {/* 基础设置 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.browser.baseTitle')}</h4>

        <div className="setting-row">
          <div className="setting-row-text">
            <label htmlFor="browser-enable">{t('settings.browser.enable')}</label>
            <span className="param-hint">{t('settings.browser.enableHint')}</span>
          </div>
          <input id="browser-enable" type="checkbox" checked={enabled} onChange={e => setEnabled(e.target.checked)} />
        </div>

        <div className="setting-row">
          <div className="setting-row-text">
            <label>{t('settings.browser.importChrome')}</label>
            <span className="param-hint">{t('settings.browser.importChromeHint')}</span>
          </div>
          <button type="button" className="btn" disabled title={t('settings.browser.importPlanned')}>
            {t('settings.browser.importData')}
          </button>
        </div>

        <p className="param-hint">{t('settings.browser.securityNote')}</p>
        <div className="setting-row">
          <div className="setting-row-text">
            <label htmlFor="browser-cert">{t('settings.browser.ignoreCert')}</label>
            <span className="param-hint">{t('settings.browser.ignoreCertHint')}</span>
          </div>
          <input id="browser-cert" type="checkbox" checked={ignoreCert} onChange={e => setIgnoreCert(e.target.checked)} />
        </div>
      </section>

      {/* 浏览器数据 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.browser.dataTitle')}</h4>
        <p className="param-hint">{t('settings.browser.dataNote')}</p>

        <div className="hooks-actions">
          <button type="button" className="btn" disabled title={t('settings.browser.clearCachePlanned')}>
            {t('settings.browser.clearCache')}
          </button>
        </div>
        <p className="param-hint">{t('settings.browser.clearCacheHint')}</p>

        <div className="setting-row">
          <div className="setting-row-text">
            <label>{t('settings.browser.clearAll')}</label>
            <span className="param-hint">{t('settings.browser.clearAllHint')}</span>
          </div>
          <button type="button" className="btn btn--danger" disabled={!confirmClear}
            title={t('settings.browser.clearAllPlanned')}
            onClick={() => setConfirmClear(!confirmClear)}>
            {confirmClear ? t('settings.browser.confirmClear') : t('settings.browser.clearAll')}
          </button>
        </div>
        <span className="param-hint"><code>port.browser()</code>（Cookie 导入/清除经内核预留，未接线）</span>
      </section>
    </div>
  );
}

export default BrowserPanel;