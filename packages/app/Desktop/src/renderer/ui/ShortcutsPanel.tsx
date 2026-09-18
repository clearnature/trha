// 快捷键面板（应用 → 快捷键）——形态对齐 Reasonix shortcuts：
//   快捷键映射表（动作 → 组合键，本地可编辑）+ 说明。
// 接线状态：本地可编辑条目；绑定内核快捷键系统（预留 port.shortcuts()）。

import { useState } from 'react';

export interface ShortcutsPanelProps {
  t: (key: string) => string;
}

interface Shortcut { actionKey: string; combo: string; }

const DEFAULT_SHORTCUTS: Shortcut[] = [
  { actionKey: 'settings.shortcuts.newSession', combo: 'Ctrl+N' },
  { actionKey: 'settings.shortcuts.focusComposer', combo: 'Ctrl+L' },
  { actionKey: 'settings.shortcuts.approve', combo: 'Ctrl+Enter' },
  { actionKey: 'settings.shortcuts.deny', combo: 'Esc' },
  { actionKey: 'settings.shortcuts.openSettings', combo: 'Ctrl+, ' },
];

export function ShortcutsPanel({ t }: ShortcutsPanelProps) {
  const [items, setItems] = useState<Shortcut[]>(DEFAULT_SHORTCUTS);
  const [editing, setEditing] = useState<number | null>(null);
  const [draft, setDraft] = useState('');
  const [newAction, setNewAction] = useState('');
  const [newCombo, setNewCombo] = useState('');

  const addShortcut = () => {
    const a = newAction.trim(); const c = newCombo.trim();
    if (!a || !c) return;
    setItems([...items, { actionKey: a, combo: c }]);
    setNewAction(''); setNewCombo('');
  };

  return (
    <div className="settings-pagebody">
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.shortcuts.title')}</h4>
        <p className="settings-page-desc">{t('settings.shortcuts.desc')}</p>

        <div className="shortcuts-list">
          {items.map((s, i) => (
            <div key={s.actionKey + i} className="shortcut-row">
              <span>{t(s.actionKey)}</span>
              {editing === i ? (
                <input type="text" value={draft} autoFocus
                  onChange={e => setDraft(e.target.value)}
                  onBlur={() => { if (draft.trim()) setItems(items.map((x, j) => j === i ? { ...x, combo: draft.trim() } : x)); setEditing(null); }}
                  onKeyDown={e => { if (e.key === 'Enter') { if (draft.trim()) setItems(items.map((x, j) => j === i ? { ...x, combo: draft.trim() } : x)); setEditing(null); } }}
                  aria-label={t('settings.shortcuts.combo')} />
              ) : (
                <button type="button" className="shortcut-combo" onClick={() => { setEditing(i); setDraft(s.combo); }}>
                  <kbd>{s.combo}</kbd>
                </button>
              )}
              <button type="button" className="btn btn--small" onClick={() => setItems(items.filter((_, j) => j !== i))}>✕</button>
            </div>
          ))}
        </div>

        <div className="perm-add" style={{ marginTop: 12 }}>
          <input type="text" placeholder={t('settings.shortcuts.actionPh')} value={newAction}
            onChange={e => setNewAction(e.target.value)} />
          <input type="text" placeholder={t('settings.shortcuts.comboPh')} value={newCombo}
            onChange={e => setNewCombo(e.target.value)} />
          <button type="button" className="btn btn--primary" onClick={addShortcut}>{t('settings.perms.add')}</button>
        </div>
        <span className="param-hint"><code>port.shortcuts()</code>（绑定内核快捷键预留，未接线）</span>
      </section>
    </div>
  );
}

export default ShortcutsPanel;