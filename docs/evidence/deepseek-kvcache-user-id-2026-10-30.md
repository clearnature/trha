# DeepSeek KVCache 与 `user_id` 的实测（2026-10-30）

> 判据用途：决定 trha 是否要按会话传 `user_id`。此前只有「官方说 user_id 用于
> KVCache 隔离」这条文档表述，没有本仓的一手数据；本文补上。

## 1. 官方规则（摘要）

- **并发**（账号级）：`deepseek-flash` 2500、`deepseek-v4-pro` 500；一个请求从
  发出到响应完成记为一个并发；超限返回 429。**与 API Key 无关**。
- **`user_id`**：OpenAI 接口放请求体顶层；Anthropic 接口放 `metadata.user_id`。
  官方列出三个用途：内容安全隔离、**KVCache 隔离**、调度隔离。
- 余额查询**没有**频率限制（只有上面那条并发限制）。
- 请求保活：非流式返回空行、流式返回 `: keep-alive`；10 分钟未开始推理则断连。

## 2. 实测

方法：同一段固定 prompt（≈754 tokens），连发两次，读 `usage.prompt_cache_hit_tokens`
与 `prompt_cache_miss_tokens`。三组对照：

| 组 | 第 1 次 | 第 2 次 | 第 2 次命中率 |
|---|---|---|---|
| **A 相同 `user_id`**（`probe-same` ×2） | hit=0 / miss=999 | hit=768 / miss=231 | **76.9%** |
| **B 不同 `user_id`**（`probe-b1` → `probe-b2`） | hit=0 / miss=999 | hit=0 / miss=999 | **0.0%** |
| **C 不带 `user_id`**（基线） | hit=0 / miss=999 | hit=768 / miss=231 | **76.9%** |

复现脚本要点（`deepseek-flash`，`max_tokens=4`，两次调用间间隔 800 ms）：

```js
const body = { model: 'deepseek-flash', max_tokens: 4,
  messages: [{ role: 'user', content: PROMPT }] };
if (userId !== undefined) body.user_id = userId;   // 官方格式：请求体顶层
```

### 结论

1. **隔离确实生效且彻底**：只换 `user_id`，命中率从 76.9% 掉到 **0%**。
2. **`user_id` 本身不降低命中**：A 组与 C 组完全一致（76.9%），只要前后一致。
3. **缓存键是「账号 + prompt 前缀」，不含会话维度**——这是 C 组能命中的原因。

## 3. 三家实现的做法（截至 2026-10-30）

| 项目 | 是否传 API 的 `user_id` | 备注 |
|---|---|---|
| **DSH**（`deepseek-harness`） | ❌ 不传 | 用 HTTP header `x-deepseek-harness-user-id` + `x-deepseek-harness-session-id` + `x-deepseek-harness-compact` 做**自家**追踪；`resolveUserId` 返回进程内恒定的匿名 ID（`userId ??= getOrCreateAnonymousUserId()`），与缓存隔离无关 |
| **reasonix** | ❌ 不传 | 配置里只有 bot 场景的 `[bot.self_user_ids]`（识别自己发的消息）；缓存命中率在本地统计 |
| **trha** | ❌ 不传（`API/Server.hs` 无 `user_id`） | 与上面两家一致 |

三家共同的选择：**不做 provider 侧隔离，换取跨会话前缀复用**。

## 4. 对 trha 的含义

- 当前 97%+ 的会话累计命中率，主体来自**同一会话内的多轮前缀复用**（每轮复用
  之前全部内容），而不是跨会话共享。
- 如果按 `user_id = sessionId`：**同会话内不受影响**（前后 id 相同），代价只是
  失去"跨会话复用同一系统提示"这一部分。
- 因此这个取舍比"命中率会崩"的直觉小得多，但仍是有失有得。

## 5. 建议（未实施）

- **单人 / 信任环境**：维持现状（不传 `user_id`）。
- **多用户共用同一 API key 且要求互不可见**：值得按 `user_id = sessionId` 隔离，
  收益是 KVCache / 调度 / 内容安全三重隔离，代价是跨会话缓存不再共享。
- 若实施，改动点：内核 `API/Server.hs` 透传 `user_id`、scheduler 建会话时带
  `sessionId`。**改前先以此文的数据为准，不要凭空评估缓存损失。**
