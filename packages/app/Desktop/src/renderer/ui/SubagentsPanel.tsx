// 子智能体面板（能力扩展 → 子智能体）——形态对齐 Reasonix Subagents 页：
//   工具栏：搜索子智能体… + 新建 + 重新扫描
//   自定义子智能体：你创建或加载的 Profile（可编辑项可管理）——预留
//   内置子智能体：explore / research / review / security-review（工具数/描述/
//                聊天命令/复制命令 + 模型/推理强度选择）——产品内置，静态呈现，
//                数据源与命令执行预留（port.subagents() / /<name> 命令待接）

import { useState } from 'react';

export interface SubagentsPanelProps {
  t: (key: string) => string;
}

export interface BuiltinSubagent {
  name: string;
  toolCount: number;
  descKey: string;
  command: string;
}

const BUILTINS: BuiltinSubagent[] = [
  { name: 'explore', toolCount: 5, descKey: 'settings.subagents.exploreDesc', command: '/explore <任务>' },
  { name: 'research', toolCount: 6, descKey: 'settings.subagents.researchDesc', command: '/research <任务>' },
  { name: 'review', toolCount: 7, descKey: 'settings.subagents.reviewDesc', command: '/review <任务>' },
  { name: 'security-review', toolCount: 7, descKey: 'settings.subagents.securityReviewDesc', command: '/security-review <任务>' },
];

export function SubagentsPanel({ t }: SubagentsPanelProps) {
  const [query, setQuery] = useState('');
  const [copied, setCopied] = useState<string | null>(null);
  // 每个内置可覆盖模型/推理强度（本地状态；persist 到内核预留）
  const [models, setModels] = useState<Record<string, string>>({});
  const [efforts, setEfforts] = useState<Record<string, string>>({});

  const visible = BUILTINS.filter(b => b.name.includes(query.trim()));

  const copyCommand = async (cmd: string) => {
    try { await navigator.clipboard.writeText(cmd); setCopied(cmd); setTimeout(() => setCopied(null), 1500); } catch { /* noop */ }
  };

  return (
    <div className="settings-pagebody">
      {/* 工具栏 */}
      <div className="mcp-toolbar">
        <input
          type="search"
          className="mcp-search"
          placeholder={t('settings.subagents.searchPlaceholder')}
          value={query}
          onChange={e => setQuery(e.target.value)}
          aria-label={t('settings.subagents.searchPlaceholder')}
        />
        <button type="button" className="btn btn--primary" disabled title={t('settings.subagents.createPlanned')}>
          {t('settings.subagents.create')}
        </button>
        <button type="button" className="btn" disabled title={t('settings.subagents.rescanPlanned')}>
          {t('settings.subagents.rescan')}
        </button>
      </div>

      {/* 自定义子智能体 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.subagents.customTitle')}</h4>
        <p className="settings-page-desc">{t('settings.subagents.customDesc')}</p>
        <div className="mcp-empty">
          <p>{t('settings.subagents.customEmpty')}</p>
          <code>{t('settings.subagents.customPlanned')}</code>
        </div>
      </section>

      {/* 内置子智能体 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.subagents.builtinTitle')}</h4>
        <p className="settings-page-desc">{t('settings.subagents.builtinDesc')}</p>

        {visible.map(b => (
          <div key={b.name} className="subagent-card">
            <div className="subagent-head">
              <code className="subagent-name">/{b.name}</code>
              <span className="subagent-badge">{t('settings.subagents.builtin')}</span>
              <span className="subagent-tools">{b.toolCount} {t('settings.subagents.tools')}</span>
            </div>
            <p className="subagent-desc">{t(b.descKey)}</p>
            <div className="subagent-command">
              <code>{b.command}</code>
              <button type="button" className="btn btn--small" onClick={() => void copyCommand(b.command)}>
                {copied === b.command ? t('settings.subagents.copied') : t('settings.subagents.copyCommand')}
              </button>
              <span className="param-hint">{t('settings.subagents.inChat')} · <code>/{b.name} &lt;任务&gt;</code></span>
            </div>
            <div className="subagent-overrides">
              <label>{t('settings.subagents.model')}</label>
              <select value={models[b.name] ?? 'inherit-default'} onChange={e => setModels({ ...models, [b.name]: e.target.value })}>
                <option value="inherit-default">{t('settings.subagents.inheritDefault')}</option>
                <option value="inherit-session">{t('settings.subagents.inheritSession')}</option>
              </select>
              <label>{t('settings.subagents.effort')}</label>
              <select value={efforts[b.name] ?? 'inherit'} onChange={e => setEfforts({ ...efforts, [b.name]: e.target.value })}>
                <option value="inherit">{t('settings.subagents.inherit')}</option>
                <option value="auto">auto</option>
                <option value="low">low</option>
                <option value="medium">medium</option>
                <option value="high">high</option>
              </select>
              <span className="param-hint"><code>{b.name}Model / {b.name}Effort</code>（预留）</span>
            </div>
          </div>
        ))}
      </section>
    </div>
  );
}

export default SubagentsPanel;