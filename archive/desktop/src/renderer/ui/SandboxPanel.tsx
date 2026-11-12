// 沙箱面板（安全与控制 → 沙箱）——形态对齐 Reasonix Sandbox 页：
//   权限模式说明 + 应用手动配置修改按钮
//   Shell 解释器：自动选择 + 当前会话/重载后使用；检测状态（bash/zsh/POSIX sh/Git）
//   允许沙箱内 bash 访问网络 开关
//   工作区根目录 / 实际可写根 + 允许写入路径
// 接线状态：本地可编辑；持久化与沙箱后端（seatbelt/bubblewrap/Windows token）预留。

import { useEffect, useState } from 'react';
import type { PortSandboxScope, PortSandboxStatus } from '../port/types.js';
import { useSessionStore } from './SessionContext.js';

export interface SandboxPanelProps {
  t: (key: string) => string;
}

interface ShellDetected { name: string; path: string | null; }

const SHELLS: ShellDetected[] = [
  { name: 'bash', path: '/usr/bin/bash' },
  { name: 'zsh', path: null },
  { name: 'POSIX sh', path: '/usr/bin/sh' },
  { name: 'Git', path: '/usr/bin/git' },
];

export function SandboxPanel({ t }: SandboxPanelProps) {
  const [interpreter, setInterpreter] = useState('auto');
  const [sessionShell, setSessionShell] = useState('bash');
  const [reloadShell, setReloadShell] = useState('bash');
  const [network, setNetwork] = useState(false);
  const [workspaceRoot, setWorkspaceRoot] = useState('');
  const [writePaths, setWritePaths] = useState('');
  const [sandbox, setSandbox] = useState<PortSandboxStatus | null>(null);
  const [scopes, setScopes] = useState<PortSandboxScope[]>([]);
  const store = useSessionStore();

  // Real backend state from the scheduler (`trha sandbox status --json` when
  // TRHA_SANDBOX is on; "none" otherwise). Failures leave the panel blank —
  // it must never claim a backend that was not probed.
  useEffect(() => {
    let alive = true;
    void store.getState().port.sandboxStatus()
      .then(s => { if (alive) setSandbox(s); })
      .catch(() => { /* status is optional */ });
    return () => { alive = false; };
  }, [store]);

  // Execution scopes (session/subagent tree) from /api/sandbox/scopes.
  useEffect(() => {
    let alive = true;
    void store.getState().port.sandboxScopes()
      .then(list => { if (alive) setScopes(list); })
      .catch(() => { /* optional */ });
    return () => { alive = false; };
  }, [store]);

  // 允许写入路径 → 内核额外可信写目录（写文件校验放宽；空 = 仅工作区）
  const syncWriteRoots = (value: string) => {
    const roots = value.split(/[,\n]/).map(s => s.trim()).filter(Boolean);
    try { void store.getState().port.setWriteRoots(roots); } catch { /* best-effort */ }
  };

  return (
    <div className="settings-pagebody">
      <p className="settings-page-desc">{t('settings.sandbox.desc')}</p>

      {/* 后端真实状态（scheduler /api/sandbox/status） */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.sandbox.backendTitle')}</h4>
        <div className="setting-group">
          <label>{t('settings.sandbox.backend')}</label>
          <p className="param-hint">{sandbox?.backend ?? '—'}</p>
        </div>
        <div className="setting-group">
          <label>{t('settings.sandbox.enforcement')}</label>
          <p className="param-hint">{sandbox?.enforcement ?? '—'}</p>
        </div>
        <div className="setting-group">
          <label>{t('settings.sandbox.available')}</label>
          <p className="param-hint">
            {sandbox
              ? (sandbox.available ? t('settings.sandbox.yes') : t('settings.sandbox.no'))
              : '—'}
          </p>
        </div>
        <div className="setting-group">
          <label>{t('settings.sandbox.scopes')}</label>
          <p className="param-hint">
            {scopes.length === 0
              ? '—'
              : scopes.slice(0, 5).map(s => `${s.id} (${s.policy})`).join(' · ')
                + (scopes.length > 5 ? ` …+${scopes.length - 5}` : '')}
          </p>
        </div>
        {sandbox?.notes?.length
          ? <p className="param-hint">{sandbox.notes.join(' · ')}</p>
          : null}
      </section>

      <div className="hooks-actions">
        <button type="button" className="btn" disabled title={t('settings.sandbox.applyPlanned')}>
          {t('settings.sandbox.apply')}
        </button>
      </div>

      {/* Shell 解释器 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.sandbox.shellTitle')}</h4>
        <div className="setting-group">
          <label>{t('settings.sandbox.shellInterpreter')}</label>
          <select value={interpreter} onChange={e => setInterpreter(e.target.value)}>
            <option value="auto">{t('settings.sandbox.shellAuto')}</option>
            <option value="bash">bash</option>
            <option value="zsh">zsh</option>
            <option value="sh">POSIX sh</option>
          </select>
        </div>
        <div className="setting-group">
          <label>{t('settings.sandbox.sessionShell')}</label>
          <select value={sessionShell} onChange={e => setSessionShell(e.target.value)}>
            <option value="bash">bash</option><option value="zsh">zsh</option><option value="sh">POSIX sh</option>
          </select>
        </div>
        <div className="setting-group">
          <label>{t('settings.sandbox.reloadShell')}</label>
          <select value={reloadShell} onChange={e => setReloadShell(e.target.value)}>
            <option value="bash">bash</option><option value="zsh">zsh</option><option value="sh">POSIX sh</option>
          </select>
        </div>
        <div className="sandbox-shells">
          {SHELLS.map(sh => (
            <div key={sh.name} className="sandbox-shell">
              <span>{sh.name}</span>
              {sh.path
                ? <span className="diag-status diag-status--passed">{t('settings.sandbox.detected')} — {sh.path}</span>
                : <span className="diag-status diag-status--not_checked">{t('settings.sandbox.notDetected')}</span>}
            </div>
          ))}
        </div>
      </section>

      {/* 网络访问 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.sandbox.networkTitle')}</h4>
        <div className="setting-row">
          <div className="setting-row-text">
            <label htmlFor="sandbox-network">{t('settings.sandbox.network')}</label>
          </div>
          <input id="sandbox-network" type="checkbox" checked={network}
            onChange={e => setNetwork(e.target.checked)} />
        </div>
      </section>

      {/* 工作区与写入路径 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.sandbox.workspaceTitle')}</h4>
        <div className="setting-group">
          <label>{t('settings.sandbox.workspaceRoot')}</label>
          <input type="text" className="hooks-editor" value={workspaceRoot}
            onChange={e => setWorkspaceRoot(e.target.value)}
            placeholder={t('settings.sandbox.workspacePlaceholder')} />
          <span className="param-hint">{t('settings.sandbox.workspaceHint')}</span>
        </div>
        <div className="setting-group">
          <label>{t('settings.sandbox.writableRoot')}</label>
          <p className="param-hint">{t('settings.sandbox.writableRootValue')}</p>
        </div>
        <div className="setting-group">
          <label>{t('settings.sandbox.writePaths')}</label>
          <input type="text" className="hooks-editor" value={writePaths}
            onChange={e => { setWritePaths(e.target.value); syncWriteRoots(e.target.value); }}
            placeholder={t('settings.sandbox.writePathsNone')} />
        </div>
        <span className="param-hint"><code>port.sandboxStatus()</code>（后端真实状态；`TRHA_SANDBOX=on` 时经 runner 探测）</span>
      </section>
    </div>
  );
}

export default SandboxPanel;