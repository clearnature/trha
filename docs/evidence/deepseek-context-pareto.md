# Context governance Pareto 实测（deepseek-flash）

日期：2026-10-24 · 命令：`npx tsx packages/scheduler/scripts/pareto-context.ts`
模型：`deepseek-flash`（`reasoning_effort: low`）· 窗口：1000（刻意压小以便触发治理）· 12 轮

脚本走的是生产代码 `packages/scheduler/src/Server/contextGovernor.ts` 的 `govern()`，
与 scheduler 在每次请求前的调用完全一致。质量轴是「第一轮埋的暗号能否在最后复述」。

| arm | calls | prompt | hit% | cache hit | cache miss | completion | billed units | max prompt | p50 ms | resets | recall | final answer |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| none | 13 | 15078 | 83.19% | 12544 | 2534 | 56 | 3844 | 1960 | 97 | 0 | yes | 蓝鲸-7319 |
| fold | 13 | 6348 | 56.46% | 3584 | 2764 | 91 | 3213 | 854 | 86 | 2 | NO | 无法查看被折叠的此前对话，因此我不知道第一个问题中的暗号。 |
| fold+keephead | 13 | 6588 | 54.40% | 3584 | 3004 | 18 | 3380 | 879 | 92 | 2 | yes | 蓝鲸-7319 |

`billed units = miss + 0.1·hit + completion`（缓存折扣 0.1 是保守假设，可用
`PARETO_CACHED_RATE` 覆盖；真实计价请给 `TRHA_PRICE_INPUT/CACHED/OUTPUT`，
`/api/usage-stats` 会据此算钱，否则显示 `—` 而不是编一个数）。

## 结论

**Pareto 前沿 = { fold, fold+keephead }**

- `none` 被 `fold+keephead` 支配：billed 3844 → 3380（−12%），prompt 总量 15078 → 6588（−56%），
  峰值 prompt 1960 → 879，recall 相同。
- `fold` 是点数最低的（3213），但把任务陈述一起折掉，recall 直接丢 —— 便宜但不可用。
- `fold+keephead` 只比 `fold` 贵 5.2%（167 units），换回 100% 召回：**保留 system + 首条
  用户消息**是这次实验里性价比最高的一个开关。

## 两个反直觉点

1. **命中率不是成本**。`none` 的 hit% 最高（83.19%），账单却最贵：它每轮都在为整段历史
   付缓存价，而缓存价不是 0。看 hit% 会让决策跑偏，必须看 billed。
2. **压缩会砸命中率**。`fold` 系列 resets=2，hit% 掉到 ~55%，因为折一次就换了一个前缀。
   所以治理必须「触发少、触发后稳定」：阈值制 + 折叠后不再变动（标记里没有时间戳/随机数，
   单元测试钉住了逐字节确定性）。

## 复现

```bash
DEEPSEEK_API_KEY=… npx tsx packages/scheduler/scripts/pareto-context.ts
```

脚本只做 3 条臂 × 13 次调用（filler 请求 `max_tokens: 1`，只有最后一次问暗号给 256），
单次实验约 2.8 万 prompt token，成本可忽略。

## 与缓存探针的关系

- `test/DeepSeekCacheSpec.hs`（Haskell，需 `DEEPSEEK_API_KEY`）：证明内核真实的
  provider 路径在稳定前缀下稳态命中 **99.54%**（req2–4: 99.57/99.54/99.51）。
- 本实验（TS，走 scheduler 的治理代码）：证明「为了省钱而压缩」会在压缩点把命中率
  打到 ~55%，因此治理的阈值必须按窗口设，且压缩后前缀要保持稳定。
