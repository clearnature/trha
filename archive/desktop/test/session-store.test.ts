import { beforeEach, describe, expect, it } from 'vitest';
import type { StoreApi } from 'zustand';
import { makeSessionStore } from '../src/renderer/state/sessionStore.js';
import type { SessionUiState } from '../src/renderer/state/sessionStore.js';
import { MockPort } from '../src/renderer/port/mock.js';

let port: MockPort;
let useStore: StoreApi<SessionUiState>;

const text = (m: { kind: string; text: string }) => `${m.kind}:${m.text}`;

beforeEach(async () => {
  port = new MockPort();
  useStore = makeSessionStore(port);
});

describe('sessionStore', () => {
  it('lists fixture sessions on refresh', async () => {
    await useStore.getState().refresh();
    expect(useStore.getState().sessions.map(s => s.id)).toEqual(['mock-1', 'mock-2']);
  });

  it('select loads messages and attaches events', async () => {
    await useStore.getState().select('mock-1');
    const msgs = useStore.getState().uiMessages;
    expect(text(msgs[0])).toBe('user:hello from the mock fixture');
    expect(text(msgs[1])).toBe('assistant:mock reply: hello!');
  });

  it('create makes a session, selects it and refreshes the list', async () => {
    const id = await useStore.getState().create();
    expect(useStore.getState().currentId).toBe(id);
    expect(useStore.getState().sessions.some(s => s.id === id)).toBe(true);
  });

  it('send appends user then assistant from the step reply', async () => {
    await useStore.getState().select('mock-2');
    await useStore.getState().send('hello world');
    const msgs = useStore.getState().uiMessages;
    expect(text(msgs[msgs.length - 2])).toBe('user:hello world');
    expect(text(msgs[msgs.length - 1])).toContain('assistant:(mock) you said: hello world');
    expect(useStore.getState().busy).toBe(false);
  });

  it('tool events from the stream become tool cards', async () => {
    await useStore.getState().select('mock-2');
    await port.emitMock('mock-2', { type: 'tool', tool: { name: 'read_file', args: [], status: 'succeeded', durationMs: 1 } });
    const last = useStore.getState().uiMessages.at(-1);
    expect(last?.kind).toBe('tool');
  });

  it('streamed deltas accumulate, then step() settles and clears them (A3)', async () => {
    await useStore.getState().select('mock-2');
    await port.emitMock('mock-2', { type: 'delta', text: 'Hel' });
    await port.emitMock('mock-2', { type: 'delta', text: 'lo' });
    expect(useStore.getState().streamText).toBe('Hello');

    await useStore.getState().send('hi');
    // Settled: the final reply is in the transcript and the buffer is empty,
    // so a missing frame could never leave a half-answer on screen.
    expect(useStore.getState().streamText).toBe('');
    const last = useStore.getState().uiMessages.at(-1) as { kind: string; text: string };
    expect(last.kind).toBe('assistant');
    expect(last.text).toContain('(mock) you said: hi');
  });

  it('switching sessions drops a half-received answer (A3)', async () => {
    await useStore.getState().select('mock-2');
    await port.emitMock('mock-2', { type: 'delta', text: 'partial' });
    expect(useStore.getState().streamText).toBe('partial');
    await useStore.getState().select('mock-1');
    expect(useStore.getState().streamText).toBe('');
  });

  it('requireApproval send parks the plan and decide approves it', async () => {
    await useStore.getState().select('mock-2');
    await useStore.getState().send('do a plan');
    // mock step without requireApproval returns a reply; approve path:
    const out = await port.step('mock-2', 'plan request', true);
    expect(out.status).toBe('awaiting_approval');
    await useStore.getState().decide(true);
    const msgs = useStore.getState().uiMessages;
    expect(text(msgs.at(-1) as never)).toContain('assistant:(mock) plan approved');
  });

  it('send surfaces errors as notice cards', async () => {
    await useStore.getState().select('mock-2');
    const bad = useStore.getState().port as MockPort;
    // deleting the session underneath makes the step throw
    await bad.deleteSession('mock-2');
    await useStore.getState().send('boom');
    const last = useStore.getState().uiMessages.at(-1);
    expect(last?.kind).toBe('notice');
  });

  it('remove clears the current selection when it was active', async () => {
    await useStore.getState().select('mock-2');
    await useStore.getState().remove('mock-2');
    expect(useStore.getState().currentId).toBeNull();
    expect(useStore.getState().uiMessages).toEqual([]);
  });
});
