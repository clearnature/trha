# 会话真相契约（session truth）

> **日期**：2026-10-27 ｜ **状态**：生效（用户裁定「两类权威」）
> **背景**：会话数据目前存在三处——内核 checkpoint + 事件日志、scheduler `stateStore`、CLI `transcript.jsonl`。
> 本契约规定**每一类事实的唯一权威**，其余位置只能投影或缓存。

---

## 1. 两类权威

| 类别 | 内容 | 唯一权威 | 其它位置 |
|---|---|---|---|
| **A. 模型可见历史** | `user` / `assistant` / `tool` 消息、工具调用与结果、审批请求与决定、计划相位变化 | **内核事件日志**（`SessionEvent` + checkpoint） | scheduler `messages`、CLI `transcript.jsonl` 都是**投影/缓存** |
| **B. UI 元数据** | `title`、`tags`、`todos`、`goal`、`schedules`、`presentations`、`permissionMode`、`planMode`、`parentId`、`cwd` | **scheduler `PersistedSession`** | 内核**不持有**这一类；CLI 只读 |

**判据**：一个事实如果会改变模型看到的上下文，它属于 A；如果只影响界面，它属于 B。

---

## 2. 恢复规则

| 场景 | 行为 |
|---|---|
| **内核重启** | 从 `stateDir` 的 checkpoint + 事件日志恢复 FSM、计划、历史；缺失则从 `Idle` 开始 |
| **scheduler 重启** | 从 `stateStore` 恢复 B 类元数据；A 类**必须**从内核重新获取（或校验一致），不得凭空保留 |
| **CLI 重启 / resume** | 向 scheduler 拉取会话；`transcript.jsonl` 仅用于离线回放，**不参与恢复** |
| **三处同时存在** | A 类以内核为准；若 scheduler 的 `messages` 与内核日志不一致，以内核重建结果覆盖并记录告警 |

---

## 3. 一致性要求

1. **可重建**：给定内核事件日志，必须能重建出与 scheduler `messages` 相同的序列
   （顺序、role、content、`tool_calls`/`tool` 结果）。
2. **审批可见**：一次批准/拒绝必须同时体现在
   - 内核：`ApprovalDecided` 事件 + FSM 离开 `AwaitingApproval`；
   - scheduler：`pendingApproval` 清除；
   - 外壳：收到终态事件（`agent:decision` 或等价）。
3. **计划一致**：内核 `Planning`/`ExecutingStep` 与 scheduler 的 `planMode`/步骤状态不得矛盾；
   scheduler 只转发，不自行推断步骤结果。

---

## 4. 迁移路线

| 阶段 | 内容 | 状态 |
|---|---|---|
| **1（本次）** | 本文契约 + 一致性校验测试（不改数据流） | ✅ 文档 + 测试：`test/SessionTruthSpec.hs`（3 例，内核侧）与 `packages/scheduler/test/session-truth.test.ts`（3 例，scheduler 侧）；两侧使用同一 fixture |
| **2** | scheduler `messages` 改为**由内核日志投影**，删除独立累积 | 待排期 |
| **3** | CLI `transcript.jsonl` 明确标注「只读回放」，resume 只走 scheduler | 待排期 |

阶段 1 的测试建议（放在 `packages/scheduler/test/`）：

```
给定一个 session：
  写入内核（/session/start → /agent/step 若可用）
  读取内核事件日志（新增只读端点或 stateDir 文件）
  读取 scheduler /api/session/:id/messages
  断言：两者按 (role, content) 序列相等
  再做一次 approval → decision
  断言：两边都看到 decided，且 scheduler 的 pendingApproval 为 null
```

> 注：当前内核没有「导出事件日志」的公开端点，阶段 1 可直接读 `stateDir` 下的 JSONL；
> 阶段 2 再加只读端点（`GET /session/:id/events`），避免测试依赖磁盘布局。

---

## 5. 已知差距（截至 2026-10-27）

- scheduler `runStep` 在内存 `session.messages` 里独立累积，内核 `agentStepHandler`/`touchKernelSession` 也写事件日志；
  两者**没有自动校验**，漂移只会被用户看到（例如消息顺序错乱）。
- CLI `transcript.jsonl` 与 scheduler 的 `messages` 是两条独立写入路径。
- 本契约只规定方向；阶段 2/3 才消除双写。

---

## 6. 核实命令

```bash
# A 类权威：内核事件日志与 checkpoint
rg -n "appendEvent|persistStep|restoreSession" src/api/API/Server.hs src/core/Core/Session/*.hs

# B 类权威：scheduler 元数据
sed -n 20,60p packages/scheduler/src/Server/stateStore.ts

# CLI 只读缓存
rg -n "transcript.jsonl|appendEvent" packages/app/CLI/Core/Transcript.hs

# 当前是否存在独立累积
rg -n "session.messages.push|persistSession" packages/scheduler/src/Server/index.ts | head
```
