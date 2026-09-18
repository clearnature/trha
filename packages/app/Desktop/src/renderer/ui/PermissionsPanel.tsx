// 权限面板（安全与控制 → 权限）——形态对齐 Reasonix Permissions 页：
//   细粒度规则：deny / ask / allow 三层；规则格式 ToolName、ToolName(glob) 或
//   Bash(command:*)。优先级 deny > ask > allow；Shell 语法由权限沙箱统一判定。
//   各层：现有规则列表（可删除）+ 添加输入框（本地增删可用；持久化预留）。
// 接线状态：规则列表本地可编辑（添加/删除），持久化到权限配置预留
//          （port.permissions() save 待接）；真实执行优先级由内核权限沙箱判定。

import { useState } from 'react';

export interface PermissionsPanelProps {
  t: (key: string) => string;
}

type RuleKind = 'deny' | 'ask' | 'allow';

export interface PermRule { kind: RuleKind; pattern: string; }

export function PermissionsPanel({ t }: PermissionsPanelProps) {
  // 预留数据源：const rules = await port.permissions()（Port 接口待加）
  const [rules, setRules] = useState<PermRule[]>([
    // 示例（Reasonix 语义）：allow 一条 Bash 命令
    { kind: 'allow', pattern: "Bash(go version -m … | grep -iE 'dashscope|provider/(anthropic|openai|dashscope)' ; echo exit=$?)" },
  ]);
  const [inputs, setInputs] = useState<Record<RuleKind, string>>({ deny: '', ask: '', allow: '' });

  const addRule = (kind: RuleKind) => {
    const pattern = inputs[kind].trim();
    if (!pattern) return;
    setRules([...rules, { kind, pattern }]);
    setInputs({ ...inputs, [kind]: '' });
  };

  const removeRule = (idx: number) => setRules(rules.filter((_, i) => i !== idx));

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