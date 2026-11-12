// 更新面板（应用 → 更新）——形态对齐 Reasonix Updates 页：
//   版本/构建身份/更新日志/帮助反馈；自动检查新版本开关；
//   匿名启动统计/共享聚合质量指标 开关；配置文件路径展示。
// 接线状态：开关本地；版本真实值从 sessionStore（version）；检查/统计经内核预留。

import { useState } from 'react';
import { useSession } from './SessionContext.js';

export interface UpdatesPanelProps {
  t: (key: string) => string;
}

const RELEASE_CHANNEL = 'stable';
const CONFIG_PATH = '/home/yanli/.trha/config.toml';

export function UpdatesPanel({ t }: UpdatesPanelProps) {
  const version = useSession(s => s.version);
  const [autoCheck, setAutoCheck] = useState(true);
  const [telemetry, setTelemetry] = useState(true);
  const [metrics, setMetrics] = useState(true);

  return (
    <div className="settings-pagebody">
      {/* 版本与构建身份 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.updates.versionTitle')}</h4>
        <p className="updates-version">当前版本：<strong>{version ? version.current : '—'}</strong></p>
        <div className="setting-group">
          <label>{t('settings.updates.channel')}</label>
          <p className="param-hint">{RELEASE_CHANNEL} · {t('settings.updates.channelHint')}</p>
        </div>
        <div className="hooks-actions">
          <button type="button" className="btn" disabled title={t('settings.updates.visitPlanned')}>{t('settings.updates.visit')}</button>
          <button type="button" className="btn" disabled title={t('settings.updates.changelog')}>{t('settings.updates.changelog')}</button>
        </div>
        <p className="param-hint">{t('settings.updates.changelogHint')}</p>
      </section>

      {/* 帮助与反馈 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.updates.helpTitle')}</h4>
        <p className="param-hint">{t('settings.updates.helpHint')}</p>
        <div className="hooks-actions">
          <button type="button" className="btn" disabled title={t('settings.updates.filePlanned')}>{t('settings.updates.fileIssue')}</button>
          <button type="button" className="btn" disabled title={t('settings.updates.viewPlanned')}>{t('settings.updates.viewIssues')}</button>
        </div>
      </section>

      {/* 自动检查 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.updates.autoCheckTitle')}</h4>
        <div className="setting-row">
          <div className="setting-row-text">
            <label htmlFor="updates-autocheck">{t('settings.updates.autoCheck')}</label>
            <span className="param-hint">{t('settings.updates.autoCheckHint')}</span>
          </div>
          <input id="updates-autocheck" type="checkbox" checked={autoCheck} onChange={e => setAutoCheck(e.target.checked)} />
        </div>
      </section>

      {/* 匿名统计与指标 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.updates.telemetryTitle')}</h4>
        <div className="setting-row">
          <div className="setting-row-text">
            <label htmlFor="updates-telemetry">{t('settings.updates.telemetry')}</label>
            <span className="param-hint">{t('settings.updates.telemetryHint')}</span>
          </div>
          <input id="updates-telemetry" type="checkbox" checked={telemetry} onChange={e => setTelemetry(e.target.checked)} />
        </div>
        <div className="setting-row">
          <div className="setting-row-text">
            <label htmlFor="updates-metrics">{t('settings.updates.metrics')}</label>
            <span className="param-hint">{t('settings.updates.metricsHint')}</span>
          </div>
          <input id="updates-metrics" type="checkbox" checked={metrics} onChange={e => setMetrics(e.target.checked)} />
        </div>
      </section>

      {/* 配置文件 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.updates.configTitle')}</h4>
        <p className="param-hint">{t('settings.updates.configPath')}: <code className="hooks-path">{CONFIG_PATH}</code></p>
        <p className="param-hint">{t('settings.updates.overrideHint')}</p>
      </section>
    </div>
  );
}

export default UpdatesPanel;