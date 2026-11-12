import { describe, expect, it } from 'vitest';
import { mergeToolEvents, parseSsePayload } from '../src/layout/sse';

describe('parseSsePayload', () => {
  it('classifies tool progress first', () => {
    const ev = parseSsePayload(JSON.stringify({ name: 'bash', status: 'running', args: ['ls'] }));
    expect(ev).toEqual({ kind: 'tool', tool: { name: 'bash', status: 'running', args: ['ls'] } });
  });

  it('classifies reasoning, text and message echoes', () => {
    expect(parseSsePayload('{"reasoning":"think"}').kind).toBe('reasoning');
    expect(parseSsePayload('{"text":"hi"}').kind).toBe('text');
    expect(parseSsePayload('{"role":"assistant"}')).toEqual({ kind: 'message', role: 'assistant' });
  });

  it('classifies step / compaction / retry notices', () => {
    expect(parseSsePayload('{"round":2,"messageCount":4,"toolCount":1}')).toEqual({
      kind: 'step', round: 2, messageCount: 4, toolCount: 1,
    });
    expect(parseSsePayload('{"trigger":"auto","savedTokens":120}')).toEqual({
      kind: 'compaction', trigger: 'auto', savedTokens: 120,
    });
    expect(parseSsePayload('{"attempt":1,"delayMs":500,"reason":"429"}')).toEqual({
      kind: 'retry', attempt: 1, delayMs: 500, reason: '429',
    });
  });

  it('treats status+message as the plan gate', () => {
    expect(parseSsePayload('{"status":"waiting","message":"approve?"}').kind).toBe('plan');
  });

  it('keeps unknown payloads', () => {
    expect(parseSsePayload('not json')).toEqual({ kind: 'unknown', raw: 'not json' });
  });
});

describe('mergeToolEvents', () => {
  it('replaces a running card with its terminal update', () => {
    const running = { name: 'bash', status: 'running' as const, args: ['ls'] };
    const done = { name: 'bash', status: 'succeeded' as const, args: ['ls'], durationMs: 12 };
    const list = mergeToolEvents([running], done);
    expect(list).toEqual([done]);
  });

  it('appends a different tool', () => {
    const a = { name: 'bash', status: 'running' as const, args: ['ls'] };
    const b = { name: 'read', status: 'running' as const, args: ['a.txt'] };
    expect(mergeToolEvents([a], b)).toEqual([a, b]);
  });

  it('does not merge past a terminal card', () => {
    const done = { name: 'bash', status: 'succeeded' as const, args: ['ls'] };
    const next = { name: 'bash', status: 'running' as const, args: ['ls'] };
    expect(mergeToolEvents([done], next)).toEqual([done, next]);
  });
});
