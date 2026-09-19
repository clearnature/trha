// @vitest-environment jsdom
// 快捷键绑定测试：验证持久化的快捷键配置真实触发动作（不光是存数据）。
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { act, renderHook } from '@testing-library/react';
import { useShortcutBindings } from '../src/renderer/ui/useShortcutBindings.js';
import { useExtSettings } from '../src/renderer/state/settingsStore.js';

describe('useShortcutBindings', () => {
  let newSession: ReturnType<typeof vi.fn>;
  let focusComposer: ReturnType<typeof vi.fn>;
  let approvePlan: ReturnType<typeof vi.fn>;
  let toggleSettings: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    localStorage.clear();
    newSession = vi.fn();
    focusComposer = vi.fn();
    approvePlan = vi.fn();
    toggleSettings = vi.fn();
  });

  const fire = (ctrl: boolean, key: string) => {
    const ev = new KeyboardEvent('keydown', { key, ctrlKey: ctrl, bubbles: true });
    window.dispatchEvent(ev);
  };

  it('Ctrl+N 触发新建会话（默认快捷键）', async () => {
    renderHook(() => useShortcutBindings({ newSession, focusComposer, approvePlan, toggleSettings }));
    await act(async () => { fire(true, 'n'); });
    expect(newSession).toHaveBeenCalled();
  });

  it('Ctrl+, 触发打开设置', async () => {
    renderHook(() => useShortcutBindings({ newSession, focusComposer, approvePlan, toggleSettings }));
    await act(async () => { fire(true, ','); });
    expect(toggleSettings).toHaveBeenCalled();
  });

  it('用户自定义快捷键 combo 后生效（持久化 store 驱动）', async () => {
    // 修改持久化快捷键：把 openSettings 改成 Ctrl+K
    // 改持久化 store 的 data（zustand setState；等效用户改快捷键 → 触发同理）
    const cur = useExtSettings.getState().shortcuts;
    const idx = cur.findIndex(s => s.action === 'settings.shortcuts.openSettings');
    if (idx >= 0) {
      const next = cur.map((s, i) => i === idx ? { ...s, combo: 'Ctrl+K' } : s);
      await act(async () => { useExtSettings.setState({ shortcuts: next }); });
    }
    renderHook(() => useShortcutBindings({ newSession, focusComposer, approvePlan, toggleSettings }));
    await act(async () => { fire(true, 'k'); });
    expect(toggleSettings).toHaveBeenCalled();
    // Ctrl+, 不再触发（已改绑定）
    await act(async () => { fire(true, ','); });
    expect(toggleSettings).toHaveBeenCalledTimes(1);
  });

  it('输入框内不拦截（除全局级）', async () => {
    renderHook(() => useShortcutBindings({ newSession, focusComposer, approvePlan, toggleSettings }));
    const input = document.createElement('input');
    document.body.appendChild(input);
    input.focus();
    await act(async () => {
      const ev = new KeyboardEvent('keydown', { key: 'n', ctrlKey: true, bubbles: true });
      input.dispatchEvent(ev);
    });
    expect(newSession).not.toHaveBeenCalled();
    document.body.removeChild(input);
  });
});