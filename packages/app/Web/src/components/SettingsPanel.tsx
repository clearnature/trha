import React, { useEffect, useState } from 'react';
import { useAppStore } from '../stores/appStore';

interface SettingsPanelProps { onClose: () => void; }

type SectionId =
  | 'account'
  | 'general'
  | 'models'
  | 'plugins'
  | 'agents'
  | 'skills'
  | 'market';

const SECTIONS: { id: SectionId; label: string }[] = [
  { id: 'account', label: '账号与余额' },
  { id: 'general', label: '通用设置' },
  { id: 'models', label: '模型' },
  { id: 'plugins', label: '内置插件' },
  { id: 'agents', label: 'Agent 预设' },
  { id: 'skills', label: '技能' },
  { id: 'market', label: '插件市场' },
];

function money(balance: { currency: string; total: number } | null): string {
  if (!balance) return '—';
  const symbol = balance.currency === 'CNY' ? '¥' : '';
  return `${symbol}${balance.total.toFixed(2)}`;
}

/**
 * Settings, structured like dsh's settings shell: a section rail on the left
 * and one section body on the right. Sections without a scheduler surface yet
 * show an explicit empty state rather than fake controls.
 */
export function SettingsPanel({ onClose }: SettingsPanelProps) {
  const {
    theme, setTheme, models, plugins, balance,
    loadPlugins, loadBalance,
  } = useAppStore();
  const [section, setSection] = useState<SectionId>('account');

  useEffect(() => {
    void loadPlugins();
    void loadBalance();
  }, [loadPlugins, loadBalance]);

  return (
    <div className="settings-panel" role="dialog" aria-modal="true" aria-label="设置">
      <div className="settings-shell">
        <nav className="settings-nav" aria-label="设置分区">
          <div className="settings-nav-title">设置</div>
          {SECTIONS.map((s) => (
            <button
              key={s.id}
              className={`settings-nav-item ${section === s.id ? 'active' : ''}`}
              onClick={() => setSection(s.id)}
            >
              {s.label}
            </button>
          ))}
          <div className="settings-nav-spacer" />
          <button className="settings-nav-item" onClick={onClose}>关闭</button>
        </nav>

        <div className="settings-body">
          {section === 'account' && (
            <section className="settings-section">
              <h2>账号与余额</h2>
              <div className="account-card">
                <div className="account-row">
                  <span className="account-label">DeepSeek</span>
                  <span className={`account-state ${balance ? 'signed-in' : ''}`}>
                    {balance ? '已登录' : '未登录'}
                  </span>
                </div>
                <div className="account-row">
                  <span className="account-label">余额</span>
                  <span className="account-balance">{money(balance)}</span>
                </div>
                <div className="account-actions">
                  <a
                    className="settings-action"
                    href="https://platform.deepseek.com"
                    target="_blank"
                    rel="noreferrer"
                  >
                    DeepSeek 网页登录
                  </a>
                  <button className="settings-action" onClick={onClose}>关闭</button>
                </div>
              </div>
              <p className="settings-note">
                余额来自当前生效的 provider（`~/.trha/providers.json`）。
              </p>
            </section>
          )}

          {section === 'general' && (
            <section className="settings-section">
              <h2>通用设置</h2>
              <div className="settings-field">
                <label htmlFor="theme-select">外观</label>
                <select
                  id="theme-select"
                  value={theme}
                  onChange={(e) => setTheme(e.target.value as 'light' | 'dark')}
                >
                  <option value="dark">深色</option>
                  <option value="light">浅色</option>
                </select>
              </div>
            </section>
          )}

          {section === 'models' && (
            <section className="settings-section">
              <h2>模型</h2>
              <div className="settings-list">
                {models.map((m) => (
                  <div key={m.name} className="settings-list-item">
                    <strong>{m.name}</strong>
                    <span>{m.description}</span>
                    <span className="settings-list-meta">{(m.contextSize / 1024).toFixed(0)}K ctx</span>
                  </div>
                ))}
                {models.length === 0 && <div className="settings-empty">暂无模型</div>}
              </div>
            </section>
          )}

          {section === 'plugins' && (
            <section className="settings-section">
              <h2>内置插件</h2>
              <div className="settings-list">
                {plugins.map((p) => (
                  <div key={p.name} className="settings-list-item">
                    <strong>{p.name}</strong>
                    {p.version && <span className="settings-list-meta">v{p.version}</span>}
                    {p.description && <span>{p.description}</span>}
                  </div>
                ))}
                {plugins.length === 0 && <div className="settings-empty">暂无已注册插件</div>}
              </div>
            </section>
          )}

          {section === 'agents' && (
            <section className="settings-section">
              <h2>Agent 预设</h2>
              <div className="settings-empty">
                尚未接入：agent 定义位于 `~/.trha/agents/` 与 `./.trha/agents/`。
              </div>
            </section>
          )}

          {section === 'skills' && (
            <section className="settings-section">
              <h2>技能</h2>
              <div className="settings-empty">尚未接入技能目录。</div>
            </section>
          )}

          {section === 'market' && (
            <section className="settings-section">
              <h2>插件市场</h2>
              <div className="settings-empty">尚未配置插件市场索引。</div>
            </section>
          )}
        </div>
      </div>
    </div>
  );
}
