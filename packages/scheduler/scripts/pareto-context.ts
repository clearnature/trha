// Pareto probe: cost vs recall for context governance, against the real API.
//
// Three arms over the same scripted conversation:
//   none          – never compact (append-only; best cache, unbounded growth)
//   fold          – elide the old span once pressure crosses 80%
//   fold+keephead – same, but keep the system block and the opening user turn
//
// Metrics per arm: calls, prompt tokens by class (cache hit / miss), billed
// units, p50 latency, and whether the code word planted in the first turn
// survives to the final question. That last one is the quality axis: cost
// without it is just a number that looks good.
//
// Run: DEEPSEEK_API_KEY=… npx tsx scripts/pareto-context.ts

import { govern, DEFAULT_GOVERNANCE, type GovernedMessage } from '../src/Server/contextGovernor.js';

const MODEL = process.env.TRHA_LLM_MODEL ?? 'deepseek-flash';
const KEY = process.env.DEEPSEEK_API_KEY;
const NEEDLE = '蓝鲸-7319';
const TURNS = 12;
const WINDOW = 1000;
const FILLER = '继续处理下一批记录，保持格式一致，不需要额外解释。'.repeat(10);
/** Cached prompt tokens bill at a discount; 0.1 is a conservative stand-in. */
const CACHED_RATE = Number(process.env.PARETO_CACHED_RATE ?? '0.1');

if (!KEY) {
  console.error('DEEPSEEK_API_KEY is required');
  process.exit(1);
}

interface Usage { prompt: number; completion: number; hit: number; miss: number }

async function call(messages: GovernedMessage[], maxTokens = 16): Promise<{ text: string; usage: Usage; ms: number }> {
  const started = Date.now();
  const res = await fetch('https://api.deepseek.com/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${KEY}` },
    body: JSON.stringify({
      model: MODEL, messages, max_tokens: maxTokens,
      reasoning_effort: 'low', stream: false,
    }),
  });
  const ms = Date.now() - started;
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
  const body = (await res.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
    usage?: Record<string, number>;
  };
  const u = body.usage ?? {};
  return {
    text: body.choices?.[0]?.message?.content ?? '',
    ms,
    usage: {
      prompt: u.prompt_tokens ?? 0,
      completion: u.completion_tokens ?? 0,
      hit: u.prompt_cache_hit_tokens ?? 0,
      miss: u.prompt_cache_miss_tokens ?? 0,
    },
  };
}

interface ArmResult {
  arm: string;
  calls: number;
  prompt: number;
  hit: number;
  miss: number;
  completion: number;
  billed: number;
  maxPrompt: number;
  p50: number;
  recall: boolean;
  resets: number;
  answer?: string;
}

async function runArm(arm: string, window: number, keepFirstUser: boolean): Promise<ArmResult> {
  const cfg = { ...DEFAULT_GOVERNANCE, window, keepFirstUser };
  let messages: GovernedMessage[] = [
    { role: 'system', content: '你是一个严谨的助手。只回答被问到的内容，不要展开。' },
    { role: 'user', content: `任务说明：稍后我会连续给你一批记录，请逐条确认。请记住本次会话的暗号：${NEEDLE}。` },
  ];
  const out: ArmResult = {
    arm, calls: 0, prompt: 0, hit: 0, miss: 0, completion: 0,
    billed: 0, maxPrompt: 0, p50: 0, recall: false, resets: 0,
  };
  const latencies: number[] = [];
  let lastPrompt = 0;

  for (let i = 1; i <= TURNS; i++) {
    messages.push({ role: 'user', content: `第 ${i} 批：${FILLER}` });
    // governance runs right before the request, exactly like the scheduler
    const g = govern(messages, lastPrompt, cfg);
    if (g.prefixChanged) {
      messages = g.messages;
      out.resets += 1;
    }
    const r = await call(messages, 1);   // reply is discarded; only usage matters
    latencies.push(r.ms);
    out.calls += 1;
    out.prompt += r.usage.prompt;
    out.hit += r.usage.hit;
    out.miss += r.usage.miss;
    out.completion += r.usage.completion;
    out.maxPrompt = Math.max(out.maxPrompt, r.usage.prompt);
    lastPrompt = r.usage.prompt;
    messages.push({ role: 'assistant', content: `已确认第 ${i} 批。` });
  }

  // The quality probe: recall the code word planted in turn 1.
  messages.push({ role: 'user', content: '第一个问题里给出的暗号是什么？只回答暗号本身。' });
  const g = govern(messages, lastPrompt, cfg);
  if (g.prefixChanged) { messages = g.messages; out.resets += 1; }
  const answer = await call(messages, 256);   // room for reasoning + the answer itself
  out.calls += 1;
  out.prompt += answer.usage.prompt;
  out.hit += answer.usage.hit;
  out.miss += answer.usage.miss;
  out.completion += answer.usage.completion;
  latencies.push(answer.ms);
  out.recall = answer.text.includes('7319');
  out.answer = answer.text.slice(0, 60);

  out.billed = out.miss + CACHED_RATE * out.hit + out.completion;
  latencies.sort((a, b) => a - b);
  out.p50 = latencies[Math.floor(latencies.length / 2)] ?? 0;
  return out;
}

function pct(hit: number, miss: number): string {
  const d = hit + miss;
  return d === 0 ? '—' : `${((hit / d) * 100).toFixed(2)}%`;
}

const arms: Array<[string, number, boolean]> = [
  ['none', 1_000_000_000, true],
  ['fold', WINDOW, false],
  ['fold+keephead', WINDOW, true],
];

const results: ArmResult[] = [];
for (const [name, window, keep] of arms) {
  process.stderr.write(`running arm ${name} …\n`);
  results.push(await runArm(name, window, keep));
}

const lines: string[] = [];
lines.push(`# Context governance Pareto (${MODEL}, window=${WINDOW}, turns=${TURNS})`);
lines.push('');
lines.push('| arm | calls | prompt | hit% | cache hit | cache miss | completion | billed units | max prompt | p50 ms | resets | recall | final answer |');
lines.push('|---|---|---|---|---|---|---|---|---|---|---|---|---|');
for (const r of results) {
  lines.push(`| ${r.arm} | ${r.calls} | ${r.prompt} | ${pct(r.hit, r.miss)} | ${r.hit} | ${r.miss} | ${r.completion} | ${r.billed.toFixed(0)} | ${r.maxPrompt} | ${r.p50} | ${r.resets} | ${r.recall ? 'yes' : 'NO'} | ${(r.answer ?? '').replace(/\|/g, '\\|')} |`);
}
lines.push('');
lines.push(`billed units = miss + ${CACHED_RATE}·hit + completion (cached-token discount is an assumption, set PARETO_CACHED_RATE to change it)`);

// Frontier: an arm is dominated when another is no worse on both axes.
const frontier = results.filter(r => !results.some(o =>
  o !== r && o.billed <= r.billed && (o.recall ? 1 : 0) >= (r.recall ? 1 : 0)
          && (o.billed < r.billed || (o.recall ? 1 : 0) > (r.recall ? 1 : 0))));
lines.push('');
lines.push(`Pareto frontier: ${frontier.map(r => `${r.arm} (billed ${r.billed.toFixed(0)}, recall ${r.recall ? 'yes' : 'no'})`).join(' ; ')}`);

console.log(lines.join('\n'));
