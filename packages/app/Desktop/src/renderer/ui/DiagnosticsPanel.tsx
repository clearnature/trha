// 诊断面板（自动化与开发者 → 诊断）——形态对齐 Reasonix Diagnostics 页：
//   凭据诊断：8 项检查表（location/file_type/owner/reparse_point/writable/read/
//             transactions/directory_replace_probe，各带状态徽标）
//   动作：检查写入能力 / 预览修复 / 修复凭据访问（预留）
//   前端交互记录：开关 + 导出（开关本地可用，导出预留）
//   前端诊断：错误/警告/信息计数 + workspace 摘要（预留）
//   问题栏：警告清单（预留）
// 接线状态：检查状态为静态预置样例（trha 无凭据诊断实现）；数据源预留。

import { useState } from 'react';

export interface DiagnosticsPanelProps {
  t: (key: string) => string;
}

type Status = 'passed' | 'unknown' | 'not_checked' | 'failed';

export interface CredentialCheck {
  id: string;
  labelKey: string;
  status: Status;
  detailKey: string;
}

// 预留：真实检查来自 port.diagnostics()（Port 接口待加）。
const CREDENTIAL_CHECKS: CredentialCheck[] = [
  { id: 'location', labelKey: 'settings.diag.chkLocation', status: 'passed', detailKey: 'settings.diag.chkLocationDetail' },
  { id: 'file_type', labelKey: 'settings.diag.chkFileType', status: 'passed', detailKey: 'settings.diag.chkFileTypeDetail' },
  { id: 'owner', labelKey: 'settings.diag.chkOwner', status: 'passed', detailKey: 'settings.diag.chkOwnerDetail' },
  { id: 'reparse_point', labelKey: 'settings.diag.chkReparse', status: 'passed', detailKey: 'settings.diag.chkReparseDetail' },
  { id: 'writable', labelKey: 'settings.diag.chkWritable', status: 'unknown', detailKey: 'settings.diag.chkWritableDetail' },
  { id: 'read', labelKey: 'settings.diag.chkRead', status: 'passed', detailKey: 'settings.diag.chkReadDetail' },
  { id: 'transactions', labelKey: 'settings.diag.chkTransactions', status: 'passed', detailKey: 'settings.diag.chkTransactionsDetail' },
  { id: 'directory_replace_probe', labelKey: 'settings.diag.chkDirReplace', status: 'not_checked', detailKey: 'settings.diag.chkDirReplaceDetail' },
];

export function DiagnosticsPanel({ t }: DiagnosticsPanelProps) {
  const [interactionLog, setInteractionLog] = useState(false);
  // 预留数据源：const diag = await port.diagnostics()（Port 接口待加）
  const frontendCounts = { errors: 0, warnings: 0, infos: 0 };
  const issueCount = 0;

  return (
    <div className="settings-pagebody">
      <p className="settings-page-desc">{t('settings.diag.desc')}</p>

      {/* 凭据诊断 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.diag.credTitle')}</h4>
        <p className="param-hint">{t('settings.diag.credPath')}</p>
        <div className="diag-checks">
          {CREDENTIAL_CHECKS.map(c => (
            <div key={c.id} className="diag-check">
              <span className={`diag-status diag-status--${c.status}`}>{c.status}</span>
              <div className="diag-check-text">
                <strong>{t(c.labelKey)}</strong>
                <span className="param-hint">{t(c.detailKey)}</span>
              </div>
            </div>
          ))}
        </div>
        <div className="hooks-actions">
          <button type="button" className="btn" disabled title={t('settings.diag.writeProbePlanned')}>{t('settings.diag.writeProbe')}</button>
          <button type="button" className="btn" disabled title={t('settings.diag.previewFixPlanned')}>{t('settings.diag.previewFix')}</button>
          <button type="button" className="btn btn--primary" disabled title={t('settings.diag.fixPlanned')}>{t('settings.diag.fixCred')}</button>
        </div>
      </section>

      {/* 前端交互记录 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.diag.frontendLogTitle')}</h4>
        <p className="param-hint">{t('settings.diag.frontendLogHint')}</p>
        <div className="setting-row">
          <div className="setting-row-text">
            <label htmlFor="diag-interaction">{t('settings.diag.frontendLog')}</label>
          </div>
          <input
            id="diag-interaction" type="checkbox" checked={interactionLog}
            onChange={e => setInteractionLog(e.target.checked)}
            title={t('settings.diag.exportPlanned')}
          />
        </div>
        <div className="hooks-actions">
          <button type="button" className="btn" disabled title={t('settings.diag.exportPlanned')}>{t('settings.diag.export')}</button>
        </div>
      </section>

      {/* 前端诊断 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.diag.frontendTitle')}</h4>
        <div className="mcp-stats">
          <div className="mcp-stat"><strong>{frontendCounts.errors}</strong><span>{t('settings.diag.errors')}</span></div>
          <div className="mcp-stat"><strong>{frontendCounts.warnings}</strong><span>{t('settings.diag.warnings')}</span></div>
          <div className="mcp-stat"><strong>{frontendCounts.infos}</strong><span>{t('settings.diag.infos')}</span></div>
        </div>
        <p className="param-hint"><code>{t('settings.diag.workspaceSummary')}</code>（预留）</p>
      </section>

      {/* 问题栏 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.diag.issues', { n: String(issueCount) })}</h4>
        <div className="mcp-empty">
          <p>{t('settings.diag.issuesEmpty')}</p>
          <code>{t('settings.diag.planned')}</code>
        </div>
      </section>
    </div>
  );
}

export default DiagnosticsPanel;