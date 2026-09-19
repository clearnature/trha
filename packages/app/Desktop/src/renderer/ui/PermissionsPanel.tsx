// 权限面板（安全与控制 → 权限）——形态对齐 Reasonix Permissions 页：
//   细粒度规则：deny / ask / allow 三层；规则格式 ToolName、ToolName(glob) 或
//   Bash(command:*)。优先级 deny > ask > allow；Shell 语法由权限沙箱统一判定。
//   各层：现有规则列表（可删除）+ 添加输入框（本地增删可用；持久化预留）。
// 接线状态：规则列表本地可编辑（添加/删除），持久化到权限配置预留
//          （port.permissions() save 待接）；真实执行优先级由内核权限沙箱判定。

import { useState } from 'react';
import { useExtSettings } from '../state/settingsStore.js';
import { useSessionStore } from './SessionContext.js';

export interface PermissionsPanelProps {
  t: (key: string) => string;
}

type RuleKind = 'deny' | 'ask' | 'allow';

export interface PermRule { kind: RuleKind; pattern: string; }

export function PermissionsPanel({ t }: PermissionsPanelProps) {
  // 规则持久化（localStorage 切换/重启不丢）→ 同步内核 executeTool（deny/ask/allow 真实执行）
  const rules = useExtSettings(s => s.permRules);
  const addRuleS = useExtSettings(s => s.addPermRule);
  const removeRuleS = useExtSettings(s => s.removePermRule);
  const store = useSessionStore();
  const [inputs, setInputs] = useState<Record<RuleKind, string>>({ deny: '', ask: '', allow: '' });

  // 变更后同步到内核权限规则引擎（scheduler /api/permissions）
  const syncToKernel = (next: typeof rules) => {
    try { void store.getState().port.setPermissions(next.map(r => ({ kind: r.kind, pattern: r.pattern }))); } catch { /* best-effort */ }
  };

  const addRule = (kind: RuleKind) => {
    const pattern = inputs[kind].trim();
    if (!pattern) return;
    const next = [...rules, { kind, pattern }];
    addRuleS(kind, pattern);
    syncToKernel(next);
    setInputs({ ...inputs, [kind]: '' });
  };

  const removeRule = (idx: number) => {
    const next = rules.filter((_, i) => i !== idx);
    removeRuleS(idx);
    syncToKernel(next);
  };

  const sections: { kind: RuleKind; titleKey: string; descKey: string; addPh: string }[] = [
    { kind: 'deny', titleKey: 'settings.perms.deny', descKey: 'settings.perms.denyDesc', addPh: 'settings.perms.denyPh' },
    { kind: 'ask', titleKey: 'settings.perms.ask', descKey: 'settings.perms.askDesc', addPh: 'settings.perms.askPh' },
    { kind: 'allow', titleKey: 'settings.perms.allow', descKey: 'settings.perms.allowDesc', addPh: 'settings.perms.allowPh' },
  ];

  return (
    <div className="settings-pagebody">
      <p className="settings-page-desc">{t('settings.perms.desc')}</p>

      {sections.map(sec => {
        const items = rules.filter(r => r.kind === sec.kind);
        return (
          <section className="settings-block" key={sec.kind}>
            <h4 className="settings-block-title">{t(sec.titleKey)}</h4>
            <p className="param-hint">{t(sec.descKey)}</p>

            {items.length === 0 ? (
              <div className="mcp-empty"><p>{t('settings.perms.none')}</p></div>
            ) : (
              <div className="perm-rules">
                {items.map((r, i) => (
                  <div key={r.pattern + i} className="perm-rule">
                    <code>{r.pattern}</code>
                    <button type="button" className="btn btn--small" onClick={() => removeRule(i)}
                      aria-label={t('settings.perms.remove')}>✕</button>
                  </div>
                ))}
              </div>
            )}

            <div className="perm-add">
              <input
                type="text"
                placeholder={t(sec.addPh)}
                value={inputs[sec.kind]}
                onChange={e => setInputs({ ...inputs, [sec.kind]: e.target.value })}
                onKeyDown={e => { if (e.key === 'Enter') addRule(sec.kind); }}
                aria-label={t(sec.titleKey)}
              />
              <button type="button" className="btn btn--primary" onClick={() => addRule(sec.kind)}>
                {t('settings.perms.add')}
              </button>
            </div>
          </section>
        );
      })}

      <span className="param-hint"><code>port.permissions()</code>（持久化预留，未接线）</span>
    </div>
  );
}

export default PermissionsPanel;