# DSH 工具契约对齐（字段矩阵与悬空说明）

> 2026-10-30（北京时间）。范围：`ToolDefinition` / `ToolSpec` 的可选钩子，对照
> `deepseek-harness` 的 `packages/core/tools/src/schema.ts`（`DefineToolOptions`）。
> 状态：**5/6 字段有消费点**；第六个（`presentationMeta`）的缺口是「会话重放」，不是接线。

## 为什么写这份

第六个字段空着时，后来者无法区分两种情形：

- **能力没接**（缺陷）
- **能力接好了，等上游机制**（取舍）

`deferLoading` 属于后者（DSH 自己的工具也不标），`presentationMeta` 也是。这份文档把
「等什么」写下来，避免下次有人重新怀疑、重复排查。

## 一、字段矩阵

| 字段 | trha 实现数 | DSH 对照 | 消费点 | 状态 |
|---|---|---|---|---|
| `presentCall` | **74 / 74** | 全部工具 | 事件 `view.title` → CLI 卡片标题 | ✅ |
| `presentResult` | **7** | 7（bash / workflow / edit / write / web-search / web-fetch / fs-search） | 事件 `view.title`（读**规范值**） | ✅ |
| `isConcurrencySafe` | **10** | 8 处 | `runTurn` 并发分组 | ✅ |
| `finalizeContent` | **1**（`terminal_read`） | 1（`tool-terminal`） | `renderToolValue` 的最后一环 | ✅ |
| `deferLoading` | **0** | 0 | 全链路（见 §2.2） | ✅ 与 DSH 一致 |
| `presentationMeta` | **4**（bash / edit / write / append_file） | 5 | **无** | ⚠️ 等会话重放 |

`projectContent` 未单独实现：trha 没有「结果策略」层，它与 `finalizeContent` 合并成一道。

## 二、两个「空着」的字段

### 2.1 `presentationMeta` —— 等会话重放

**它做什么**：工具把展示元数据写进事件，`(args, value) → JsonValue`。DSH 用它持久化
工具卡片的展示意图（`tool-fs/edit` 写 `{ path, diffs }`），会话恢复时重建卡片。

**trha 缺什么**：会话持久化只存 `messages`（JSONL），不存展示元数据。`session.presentations`
字段存在，但只存 `PRESENT:` 标记，不含工具调用的元数据。

**启用条件**（任一即可）：

1. 会话格式加一条 `tool-presentation` 记录，`persistSession` 时写入；
2. 恢复时读回，重建 `ToolCard`。

**为什么现在不做**：这是**新功能**（会话重放），不是补接线。四个工具的
`presentationMeta` 已经写好并进入事件，接上消费方即可用，不需要改工具。

### 2.2 `deferLoading` —— 与 DSH 一致地没人标

```bash
$ rg -rn "deferLoading" /home/yanli/work/deepseek-harness/packages/*/tool-*/src/*.ts
(空)
```

DSH 的 28 个工具包**没有一个标 `deferLoading`**。这个字段只出现在：

- `llm-deepseek` 适配层（序列化 + beta 头）
- `tests/serialize.spec.ts`（合成用例：`search` 标、`fetch` 不标）
- `apps/cli/tests/profiles/sdk/dynamic-tool-cache.e2e.ts`（端到端）

trha 照此对齐：管道通，但 74 个工具都不标。

**全链路**（已通）：

```
defineTool({ deferLoading: true })
  → ToolSpec → BridgeToolSpec → 内核 ToolSpec.tsDeferLoading
  → anthropicTools（兜底：至少一个 false）
  → "defer_loading": true
  → anthropic-beta: mid-conversation-tool-changes-2026-07-01
  → api.deepseek.com/anthropic
```

**上游约束**：DeepSeek 的 anthropic 兼容端点拒绝全部 deferred 的请求
（`tools: at least one tool must have defer_loading=false`）。`anthropicTools` 在发送前
兜底取消第一个。

**启用条件**：在某个工具上加 `deferLoading: true` 即可。**不要全标**。

## 三、四个关键设计决策

### 3.1 `output.render` 必须逐字复现原文本

工具改为结构化返回时（`bash` / `edit` / `write` / `grep` / `web_search` / `workflow`），
`render` 必须产出与改造前**完全相同**的文本。模型侧无感知，改变的只是工具层能读字段。

验证方式：原有测试断言文本，改造后仍绿。

### 3.2 `presentResult` 收规范值，不是渲染文本

管线（`a935e32`）：

```
renderToolValue → { text, value }
  → runStandardTool / runExtraTool（可选 out 参数）
  → executeTool（valueSink）
  → emitToolLifecycle（value 参数）
  → presentResult(args, value ?? output)
```

已结构化的工具读字段；还没结构化的仍是字符串（`value ?? output` 的兜底）。

### 3.3 并发分组只并行 execution

```
按 isConcurrencySafe 切批 → 批内 Promise.all(executeTool) → 按原顺序做收尾
```

事件、transcript push、持久化**全部串行**：provider 要求每个 `tool_call_id` 一条 tool
message 且按顺序，并行 push 会交错，下一轮请求直接 400。

### 3.4 契约字段集由编译器守住

```typescript
// toolSchema.ts
export const DEFINITION_FIELDS: Record<keyof ToolDefinition, true> = { ... }
```

`Record<keyof T, true>` 要求穷举。往 `ToolDefinition` 加字段却不写进这张表，编译不过。

**起因**：`registerTool` 的升级分支曾只复制 4 个字段（`plane`/`origin`/`presets`/`handler`），
导致 74 个工具的 `description` / `output` / `timeoutMs` / `presentCall` 全部静默丢失——
持续好几轮没人发现，因为原有测试只调 `handler`、从不读其它字段。

运行时那一半由 `test/tool-contract.test.ts` 覆盖：造一个「所有可选字段都设置」的工具，
断言每个字段抵达 `ToolSpec`；再造一个「都不设置」的，断言没有多余字段。

## 四、证据

```
tsc --noEmit                                                          → 通过
vitest extra-tools + tool-registry + tool-presentation + tool-contract → 54 passed
cabal build trha:exe:trha                                             → 通过
cabal test trha-cli-test                                              → 629 examples, 0 failures
```

提交（按时间）：

```
a935e32  规范化值管线
8f4e06d  bash 结构化
51ec70f  edit 结构化
d18517c  write / append_file 结构化
4123490  registerTool 字段丢失修复 + presentation 测试
6fe760a  isConcurrencySafe（按上游清单）
ab2b451 / 2b98832  presentResult（按 DSH 实现清单）
1668aad  terminal_read 的 finalizeContent
a6af2b2  grep 结构化
8304c2c  web_search 结构化
d48ebeb  web_fetch 读规范值
c71ec86  workflow 结构化
525dbad  并发分组
b99c27d / c2e1517 / bdab3d4 / 21ff437  deferLoading 全链路
```

## 五、下一步

**唯一的悬空项**是 `presentationMeta` 的消费点。接入它需要：

1. 会话格式加 `tool-presentation` 记录（`persistSession` 时写）
2. 恢复时重建 `ToolCard`

在此之前，四个工具的 `presentationMeta` 会继续写进事件但没有读者——这是**已知且记录
在案**的状态，不是遗漏。
