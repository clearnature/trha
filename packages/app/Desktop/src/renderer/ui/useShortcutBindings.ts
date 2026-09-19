// 快捷键绑定 hook：监听全局 keydown，解析持久化的快捷键 combo（settingsStore）
// 并触发对应动作（新建会话/聚焦输入框/批准计划/打开设置）。
// ⚠️ 真正让「快捷键设置页」的配置生效——此前快捷键数据存在但无代码响应。

import { useEffect } from 'react';
import { useExtSettings } from '../state/settingsStore.js';
import { useSessionStore } from './SessionContext.js';

export interface ShortcutActions {
  newSession: () => void;
  focusComposer: () => void;
  approvePlan: () => void;
  toggleSettings: () => void;
}

/** 解析 "Ctrl+N" / "Ctrl+Enter" / "Ctrl+," → {ctrl, key}（大小写不敏感、支持主流键）。 */
function parseCombo(combo: string): { ctrl: boolean; key: string } | null {
  const parts = combo.split('+').map(s => s.trim()).filter(Boolean);
  const ctrl = parts.some(p => /^ctrl$/i.test(p));
  const keyPart = parts.find(p => !/^ctrl$/i.test(p));
  if (!keyPart) return null;
  let key = keyPart.toLowerCase();
  if (key === 'enter') key = 'enter';
  else if (key.length === 1) key = key.toLowerCase();
  return { ctrl, key };
}

export function useShortcutBindings(actions: ShortcutActions): void {
  const shorts = useExtSettings(s => s.shortcuts);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const base = shorts.find(sh => {
        const c = parseCombo(sh.combo);
        return c ? (c.ctrl === e.ctrlKey && c.key === e.key.toLowerCase()) : false;
      });
      if (!base) return;
      // 输入框内不拦截（除了全局级）
      const target = e.target as HTMLElement | null;
      if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) return;
      e.preventDefault();
      switch (base.action) {
        case 'settings.shortcuts.newSession': actions.newSession(); break;
        case 'settings.shortcuts.focusComposer': actions.focusComposer(); break;
        case 'settings.shortcuts.approve': actions.approvePlan(); break;
        case 'settings.shortcuts.openSettings': actions.toggleSettings(); break;
        default: break;
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [shorts, actions]);
}
