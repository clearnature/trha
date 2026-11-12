// @vitest-environment jsdom
// 交互记录 hook 测试：验证开关开启时真实记录时间/事件/几何，且不含内容（隐私安全）。
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { act, renderHook } from '@testing-library/react';
import { useInteractionLog } from '../src/renderer/ui/useInteractionLog.js';

describe('useInteractionLog', () => {
  beforeEach(() => { vi.clearAllMocks(); });

  const fire = (input: 'input' | 'button' | 'window', type: string) => {
    let target = window;
    const el = input === 'button'
      ? (() => { const b = document.createElement('button'); b.className = 'test-btn'; document.body.appendChild(b); return b; })()
      : input === 'input'
        ? (() => { const i = document.createElement('input'); i.value = 'SECRET-CONTENT'; document.body.appendChild(i); return i; })()
        : window;
    if (el !== window) target = el;
    const ev = new Event(type, { bubbles: true });
    target.dispatchEvent(ev);
  };

  it('关闭时不记录', async () => {
    const { result } = renderHook(() => useInteractionLog(false));
    fire('button', 'click');
    expect(result.current.events.length).toBe(0);
  });

  it('开启后记录 click/geometry 且不泄露输入值', async () => {
    const { result } = renderHook(() => useInteractionLog(true));
    await act(async () => { fire('input', 'click'); });
    expect(result.current.events.length).toBeGreaterThan(0);
    const ev = result.current.events[0];
    expect(ev.type).toBe('click');
    expect(ev.geometry).toMatch(/x/);     // 有几何
    expect(JSON.stringify(ev)).not.toContain('SECRET-CONTENT');   // 隐私：无输入值
  });

  it('记录 keydown（无键值内容）', async () => {
    const { result } = renderHook(() => useInteractionLog(true));
    await act(async () => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    });
    const el = result.current.events.find(e => e.type === 'keydown');
    expect(el).toBeTruthy();
    expect(JSON.stringify(el)).not.toContain('Enter');   // 不含具体键值（隐私）
  });
});