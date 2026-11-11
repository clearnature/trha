// History invariants for the tool loop.
//
// A provider rejects — or worse, silently mis-reads — a transcript where an
// assistant turn with `tool_calls` is not immediately followed by one `tool`
// message per call id. Three real bugs came from breaking that:
//
//   * parallel calls were merged into one (index dropped at the kernel), so the
//     "call" had no id and its result answered nothing;
//   * `present` pushed a card as an assistant message *between* the calls and
//     their results;
//   * a turn-ending tool (ask_user_question / exit_plan_mode) returned without
//     recording its result, leaving the calls unanswered forever.
//
// Every scenario below runs the real loop against a scripted kernel and then
// checks the invariant on each request the kernel received — not just on the
// final transcript, because that is what the provider actually saw.

import express from 'express';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { Server } from 'http';
import type { AddressInfo } from 'net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from '../src/Server/index.js';
import { HaskellBridge } from '../src/Bridge/Haskell.js';

const auth = { 'Content-Type': 'application/json', Authorization: 'Bearer dev-token' } as Record<string, string>;

interface Msg {
  role: string;
  content?: string;
  tool_calls?: Array<{ id: string; type?: string; function?: { name?: string; arguments?: string } }>;
  tool_call_id?: string;
}

/** Every tool_calls message must be followed by exactly its results, in order. */
function assertHistory(messages: Msg[]): void {
  const seen = new Set<string>();
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i]!;
    if (m.role === 'tool') {
      expect(m.tool_call_id, `tool result at ${i} has no id`).toBeTruthy();
      expect(seen.has(m.tool_call_id!), `tool result at ${i} answers an unknown call`).toBe(true);
      continue;
    }
    const calls = m.tool_calls ?? [];
    if (m.role === 'assistant' && calls.length > 0) {
      for (const c of calls) {
        expect(c.id, `assistant at ${i} has a call without id`).toBeTruthy();
        seen.add(c.id);
      }
      const follow = messages.slice(i + 1, i + 1 + calls.length);
      expect(
        follow.map(f => f.role),
        `assistant at ${i} with ${calls.length} call(s) is not followed by ${calls.length} tool message(s)`,
      ).toEqual(calls.map(() => 'tool'));
      expect(follow.map(f => f.tool_call_id)).toEqual(calls.map(c => c.id));
    }
  }
}

interface JsonRound {
  calls?: Array<{ id: string; name: string; args: Record<string, unknown> }>;
  answer?: string;
  usage?: Record<string, number>;
}

/** Kernel that answers with plain JSON (the fallback path of the loop). */
function jsonKernel(rounds: JsonRound[], seen: Msg[][]) {
  const kernel = express();
  kernel.use(express.json());
  let round = 0;
  kernel.post('/session/start', (_q, res) => res.json({}));
  kernel.post('/v1/chat/completions', (req, res) => {
    seen.push((req.body.messages ?? []) as Msg[]);
    const script = rounds[round] ?? {};
    round += 1;
    const calls = script.calls ?? [];
    res.json({
      choices: [{
        message: calls.length > 0
          ? {
              role: 'assistant', content: '',
              tool_calls: calls.map(c => ({
                id: c.id, type: 'function',
                function: { name: c.name, arguments: JSON.stringify(c.args) },
              })),
            }
          : { role: 'assistant', content: script.answer ?? 'done', finish_reason: 'stop' },
        finish_reason: calls.length > 0 ? 'tool_calls' : 'stop',
      }],
      ...(script.usage ? { usage: script.usage } : {}),
    });
  });
  return kernel;
}

async function listen(app: express.Express): Promise<{ port: number; server: Server }> {
  const s = await new Promise<Server>(resolve => {
    const srv = app.listen(0, '127.0.0.1', () => resolve(srv));
  });
  return { port: (s.address() as AddressInfo).port, server: s };
}

describe('tool-loop history invariants', () => {
  let dir: string;
  let seen: Msg[][] = [];
  let close: () => void;

  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-hist-'));
    process.env.TRHA_WORKSPACE = dir;
    process.env.TRHA_SCHEDULE_TICK_MS = '0';
    seen = [];
  });
  afterEach(async () => {
    close?.();
    delete process.env.TRHA_WORKSPACE;
    delete process.env.TRHA_SCHEDULE_TICK_MS;
    // Windows：杀软/句柄延迟释放会让 rmdir 报 EBUSY——重试覆盖大部分，仍失败忽略。
    try {
      await rm(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    } catch { /* EBUSY: 延迟释放，非测试失败 */ }
  });

  async function boot(rounds: JsonRound[]) {
    const kernel = jsonKernel(rounds, seen);
    const kernelServer = await listen(kernel);
    const stateDir = path.join(dir, 'state');
    const { app, stop } = createServer({
      port: 0, token: 'dev-token', haskellHost: '127.0.0.1', haskellPort: kernelServer.port, stateDir,
    });
    const schedulerServer = await listen(app);
    close = () => { stop(); kernelServer.server.close(); schedulerServer.server.close(); };
    return `http://127.0.0.1:${schedulerServer.port}`;
  }

  async function start(base: string): Promise<string> {
    const res = await fetch(`${base}/api/session/start`, {
      method: 'POST', headers: auth, body: JSON.stringify({ mode: 'standard', permissionMode: 'yolo' }),
    });
    return ((await res.json()) as { sessionId: string }).sessionId;
  }

  it('keeps two parallel calls separate, with their ids', async () => {
    // Bridge level, SSE: this is the merge that glued two calls into one.
    const calls = [
      { index: 0, id: 'call_a', type: 'function', function: { name: 'todo_write', arguments: '{"todos":[]}' } },
      { index: 1, id: 'call_b', type: 'function', function: { name: 'run_code', arguments: '{"code":"1"}' } },
    ];
    const kernel = express();
    kernel.use(express.json());
    kernel.post('/v1/chat/completions/stream', (_req, res) => {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta: { tool_calls: calls } }] })}\n\n`);
      res.write(`data: ${JSON.stringify({ usage: { prompt_tokens: 100, completion_tokens: 5, total_tokens: 105, prompt_cache_hit_tokens: 80, prompt_cache_miss_tokens: 20 } })}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    });
    const kernelServer = await listen(kernel);
    const bridge = new HaskellBridge({ host: '127.0.0.1', port: kernelServer.port });
    const answer = await bridge.queryModelStream({ messages: [{ role: 'user', content: 'go' }] }, () => {});
    kernelServer.server.close();

    expect(answer.toolCalls).toHaveLength(2);
    expect(answer.toolCalls!.map(c => c.id)).toEqual(['call_a', 'call_b']);
    expect(answer.toolCalls!.map(c => c.name)).toEqual(['todo_write', 'run_code']);
    expect(answer.usage?.cacheHitTokens).toBe(80);
    expect(answer.usage?.cacheMissTokens).toBe(20);
  });

  it('compaction keeps every tool block whole', async () => {
    // A tiny window forces the governor to fold mid-conversation. The boundary
    // must land on a block edge: a tail that starts with a `tool` message would
    // orphan it, and the provider rejects that transcript.
    process.env.TRHA_CONTEXT_WINDOW = '800';
    try {
      const big = 'x'.repeat(800);
      const rounds: JsonRound[] = Array.from({ length: 6 }, (_, i) => ({
        calls: [{ id: `c${i}`, name: 'bash', args: { command: `echo ${big}` } }],
      }));
      rounds.push({ answer: 'done' });
      const base = await boot(rounds);
      const sessionId = await start(base);
      await fetch(`${base}/api/agent/step`, {
        method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'grind' }),
      });

      expect(seen.length).toBeGreaterThanOrEqual(2);
      // every request the provider saw is structurally valid ...
      for (const history of seen) assertHistory(history);
      // ... and at least one of them was actually compacted
      expect(seen.some(h => h.some(m => (m.content ?? '').includes('[context')))).toBe(true);
    } finally {
      delete process.env.TRHA_CONTEXT_WINDOW;
    }
  });

  it('puts a presented card after the tool result, never inside the call block', async () => {
    const base = await boot([
      { calls: [{ id: 'call_p', name: 'present', args: { title: 'T', body: 'B' } }] },
      { answer: 'done' },
    ]);
    const sessionId = await start(base);
    await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'show' }),
    });

    for (const history of seen) {
      assertHistory(history);
      // a card is not a model turn: nothing synthetic appears in the transcript
      expect(history.some(m => m.role === 'assistant' && (m.content ?? '').includes('[presentation]'))).toBe(false);
    }
  });

  it('records the result of a turn-ending question, so the next request is valid', async () => {
    const base = await boot([
      { calls: [{ id: 'call_q', name: 'ask_user_question', args: { question: 'which branch?' } }], answer: 'which branch?' },
      { answer: 'on dev' },
    ]);
    const sessionId = await start(base);
    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'ask me' }),
    });
    expect(((await step.json()) as { reply: string }).reply).toContain('which branch?');

    const answer = await fetch(`${base}/api/session/${sessionId}/answer`, {
      method: 'POST', headers: auth, body: JSON.stringify({ answer: 'dev' }),
    });
    expect(answer.status).toBe(200);

    // both requests the provider saw are structurally valid
    for (const history of seen) assertHistory(history);
    // the pending call was answered before the follow-up turn
    const afterQuestion = seen[1]!;
    const q = afterQuestion.find(m => (m.tool_calls ?? []).some(c => c.id === 'call_q'))!;
    const result = afterQuestion[afterQuestion.indexOf(q) + 1]!;
    expect(result).toMatchObject({ role: 'tool', tool_call_id: 'call_q' });
  });

  it('bills every model call in the tool loop, not only the last round', async () => {
    // A `ls` is two provider calls.  The footer's `in` used to read the second
    // one alone, so a tool turn looked cheaper than the bill it produced.
    const base = await boot([
      {
        calls: [{ id: 'call_u', name: 'todo_write', args: { todos: [] } }],
        usage: {
          prompt_tokens: 100, completion_tokens: 10, total_tokens: 110,
          prompt_cache_hit_tokens: 80, prompt_cache_miss_tokens: 20,
        },
      },
      {
        answer: 'done',
        usage: {
          prompt_tokens: 150, completion_tokens: 5, total_tokens: 155,
          prompt_cache_hit_tokens: 120, prompt_cache_miss_tokens: 30,
        },
      },
    ]);
    const sessionId = await start(base);
    const step = await fetch(`${base}/api/agent/step`, {
      method: 'POST', headers: auth, body: JSON.stringify({ sessionId, message: 'list it' }),
    });
    const body = await step.json() as {
      usage: {
        promptTokens: number; contextPromptTokens: number;
        completionTokens: number; cacheHitTokens: number; cacheMissTokens: number;
      };
    };

    // 100 + 150: both rounds are billed, matching the cache/completion totals
    expect(body.usage.promptTokens).toBe(250);
    expect(body.usage.cacheHitTokens).toBe(200);
    expect(body.usage.cacheMissTokens).toBe(50);
    expect(body.usage.completionTokens).toBe(15);
    // the context gauge still reads the latest request's occupancy
    expect(body.usage.contextPromptTokens).toBe(150);
  });
});
