// Subagent 侧的纯逻辑类补测：SessionManager / ProtocolHandler / SessionTruth。
// （覆盖率补强：三块此前零/低覆盖。）
import { describe, expect, it } from 'vitest';

import { SessionManager } from '../src/Subagent/State/Session.js';
import { ProtocolHandler } from '../src/Subagent/Communication/Protocol.js';
import { messagesFromEvents, type KernelEvent } from '../src/Core/SessionTruth.js';

describe('Subagent State/Session', () => {
  it('create → get / list（按 subagentId 过滤）', async () => {
    const mgr = new SessionManager();
    const a = await mgr.createSession('agent-1', 'parent-1');
    await mgr.createSession('agent-2', 'parent-1');
    expect((await mgr.getSession(a.id))?.subagentId).toBe('agent-1');
    expect(await mgr.listSessions('agent-1')).toHaveLength(1);
    expect(await mgr.listSessions('agent-2')).toHaveLength(1);
  });

  it('addMessage：追加 + 未知会话抛错', async () => {
    const mgr = new SessionManager();
    const s = await mgr.createSession('a', 'p');
    const m = await mgr.addMessage(s.id, 'user', 'hello', { k: 1 });
    expect(m.role).toBe('user');
    expect(s.messages).toHaveLength(1);
    await expect(mgr.addMessage('ghost', 'user', 'x')).rejects.toThrow('not found');
  });

  it('completeSession：置终态与 endTime；未知会话抛错', async () => {
    const mgr = new SessionManager();
    const s = await mgr.createSession('a', 'p');
    await expect(mgr.completeSession('ghost', 'failed')).rejects.toThrow('not found');
    await mgr.completeSession(s.id, 'completed');
    expect((await mgr.getSession(s.id))?.status).toBe('completed');
    expect((await mgr.getSession(s.id))?.endTime).toBeDefined();
  });
});

describe('Subagent ProtocolHandler', () => {
  it('request 分发到注册的 method；未注册方法报错', async () => {
    const p = new ProtocolHandler();
    p.registerHandler('dig', async () => 'dug');
    const out = await p.handleMessage({
      id: 'm1', type: 'request', from: 'a', to: 'b', timestamp: new Date(),
      method: 'dig', params: {},
    });
    expect(out).toBe('dug');
    await expect(p.handleMessage({
      id: 'm2', type: 'request', from: 'a', to: 'b', timestamp: new Date(),
      method: 'nope', params: {},
    })).rejects.toThrow('No handler for method: nope');
  });

  it('response / event / error 三类的透传语义', async () => {
    const p = new ProtocolHandler();
    expect(await p.handleMessage({
      id: 'r', type: 'response', from: 'a', to: 'b', timestamp: new Date(),
      requestId: 'q1', result: 'res',
    })).toBe('res');
    expect(await p.handleMessage({
      id: 'e', type: 'event', from: 'a', to: 'b', timestamp: new Date(),
      event: 'tick', data: 42,
    })).toBe(42);
    await expect(p.handleMessage({
      id: 'x', type: 'error', from: 'a', to: 'b', timestamp: new Date(),
      error: 'boom',
    })).rejects.toThrow('boom');
  });

  it('未知 type → 明确报错', async () => {
    const p = new ProtocolHandler();
    await expect(p.handleMessage({
      id: 'u', type: 'mystery', from: 'a', to: 'b', timestamp: new Date(),
    } as never)).rejects.toThrow('Unknown message type');
  });
});

describe('Core/SessionTruth — messagesFromEvents（内核日志 → 消息序列）', () => {
  it('空事件 → 空消息；重复调用幂等', () => {
    expect(messagesFromEvents([])).toEqual([]);
    const again = messagesFromEvents([]);
    expect(again).toEqual([]);
  });

  it('真实事件序列：user/assistant/tool_call/tool_result 全量重建', () => {
    const events: KernelEvent[] = [
      { kind: 'user_message', text: '问一句' },
      { kind: 'agent_state', agentState: { s: 1 } },      // 状态事件不是消息
      { kind: 'assistant_message', text: '答一句' },
      { kind: 'tool_call', tool: 'bash', payload: { command: 'ls' } },
      { kind: 'tool_result', tool: 'bash', payload: { out: 'files' } },
      { kind: 'approval_requested', approve: false },      // 状态事件不是消息
    ];
    const out = messagesFromEvents(events);
    // 4 条消息（user/assistant/tool_call→assistant/tool_result→tool）；
    // agent_state 与 approval 两类状态事件不算消息 —— 这正是 SessionTruth 的核心语义
    expect(out).toHaveLength(4);
    expect(out[0]).toEqual({ role: 'user', content: '问一句' });
    expect(out[1]).toEqual({ role: 'assistant', content: '答一句' });
    expect(out[2].role).toBe('assistant');
    expect(out[2].tool_calls?.[0].name).toBe('bash');
    expect(out[3].role).toBe('tool');
    expect(out[3].name).toBe('bash');
    expect(out[3].content).toBe(JSON.stringify({ out: 'files' }));
  });
});
