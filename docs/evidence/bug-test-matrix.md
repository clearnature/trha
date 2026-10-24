# 缺陷 × 测试 对照表

本仓这一轮（2026-10-23/24）修掉的缺陷，以及每条现在由**哪个测试**钉住。
判定口径：`已钉住` = 有断言会在回归时失败；`真机` = 只有真实 API/浏览器跑过；
`外部` = 不在本仓可测范围。

## 一、内核（Haskell）

| 缺陷 | 严重度 | 状态 | 测试 |
|---|---|---|---|
| `/session/start` 非幂等，恢复的 FSM 被重置 | P0 | 已钉住 | `test/ApprovalSpec.hs`、`test/PlanSpec.hs`（重启用例） |
| 内核与编排层同名会话文件互相覆盖 | P0 | 已钉住 | `SessionPersistSpec.hs`（namespaces its files） |
| 删除会话后快照复活 | P0 | 已钉住 | `SessionPersistSpec.hs:324` |
| 事件日志从未被写入（`appendEvent` 无调用点） | P0 | 已钉住 | `SessionPersistSpec.hs`（事件日志组 9 例） |
| `planFinished` 把"已放行"当成结束，屏障提前消失 | P0 | 已钉住 | `PlanSpec.hs`（plan only finishes…） |
| `submitPlan` 在计划进行中接受第二份计划 | P1 | 已钉住 | `PlanSpec.hs`（second plan refused） |
| 二次审批请求被当成新请求（id 相同仍返回 Just） | P1 | 已钉住 | `ApprovalSpec.hs`（second request refused） |
| 并发写会话共用 `.tmp` → ENOENT | P0 | 已钉住 | `state-store.test.ts`（20 写并发） |
| 并行 tool_calls 被合并（index 恒 0、丢 id） | P0 | 已钉住 | `StreamToolCallsSpec.hs`（3 例） |
| thinking 模式要求每条 assistant 带 `reasoning_content` | P0 | 已钉住 | `WireGuardsSpec.hs`（3 例） |
| provider 错误被吞成空回复 | P0 | 已钉住 | `WireGuardsSpec.hs`（3 例） |
| 流式 usage 未上报（无 `include_usage`） | P1 | 已钉住 | `StreamToolCallsSpec.hs`（usage 断言）+ `history-invariants`（bridge 记账） |
| 会话恢复是 `void loadSessions().then()`，重启瞬间 404 | P1 | 已钉住 | `standard-tools.test.ts`（同 id 跨进程） |

## 二、编排层（TypeScript）

| 缺陷 | 严重度 | 状态 | 测试 |
|---|---|---|---|
| `present` 把卡片插在 tool_calls 与结果之间 → 400 | P0 | 已钉住 | `history-invariants.test.ts`（3 例） |
| `ask_user_question` 结束本轮但没落工具结果 → 下一轮 400 | P0 | 已钉住 | `history-invariants.test.ts`（question→answer） |
| `Number('')===0`：子智能体深度与调度 tick 默认被禁用 | P0 | 已钉住 | `env.test.ts`（7 例） |
| `working_directory` 只改字符串，fs/bash 不跟随 | P1 | 已钉住 | `cwd-follow.test.ts` |
| `plugin_market` 未注册进工具面（unknown tool） | P1 | 已钉住 | `tool-catalog.test.ts` |
| `todo_write` 反复重写同一清单 | P1 | 已钉住 | `standard-tools-guards.test.ts`（UNCHANGED 2 例）+ `system-prompt.test.ts`（纪律在提示里） |
| `mode.persona` 是死配置（从不发 system 消息） | P1 | 已钉住 | `system-prompt.test.ts`（3 例） |
| 浏览器启动失败要等满 15s | P2 | 已钉住 | `standard-tools-guards.test.ts` |
| `stagehand_tabs` 用 `about:blank` 导航被 http 校验拒 | P2 | 已钉住 | `extra-tools.test.ts` |
| `stagehand_act` 对非表单元素写 value 无效 | P2 | 已钉住 | `extra-tools.test.ts`（改为 textContent） |
| 工具异常杀死整轮 | P1 | 已钉住 | `standard-tools-guards.test.ts`（错误转结果） |
| 一次性工具用完不清理进程（tsx 不退出） | P2 | 已钉住 | `tool-gateway-sweep.mts` 末尾显式 shutdown |

## 三、只有真机/外部验证

| 项 | 证据 |
|---|---|
| 模型是否遵守提示（todo 只写一次） | 真机 5→4 次调用；`docs/evidence/tool-gateway-sweep.md` §3 |
| 78 个工具的连通性 | 网关扫描 50 ok / 6 refused / 0 error；同文档 §1 |
| DeepSeek 前缀缓存 99%+ | `test/DeepSeekCacheSpec.hs`（需 key，默认 skip） |
| Lean4 / Python 任务闭环 | `docs/evidence/deepseek-lean-sqrt2/` |
| MCP / LSP 真实 server | 只对**假服务器**测过协议帧 |
| VPN / 服务器脚本 | 基础设施，不在本仓 |

## 四、边界与压力（原本未覆盖，现已补上）

| 项 | 修的问题 | 测试 |
|---|---|---|
| provider 超时 | `responseTimeoutNone` 意味着 provider 静默就**永久挂住**；现在按 `TRHA_STREAM_TIMEOUT_MS`（默认 20s）中断，并**保留已收到的部分内容**再报错 | `StreamTimeoutSpec.hs`（2 例：静默流中断带 `timed out`；默认值 20s/非法值回落） |
| 多智能体并发 | 两个父会话同时跑、各自 spawn 子会话：子会话不串味、`parentId` 正确 | `agents-concurrent.test.ts`（2 例） |
| 中断正在跑的智能体 | `interrupt_agent` 在目标**真的忙**时命中，目标在下一轮边界返回 `(interrupted)` | 同文件（第 2 例） |
| 调度跨天/时区 | 带偏移的 `at`（`+08:00`）按那一刻的 UTC 实例存储；未来数月不触发；过期重复任务补跑一次并把游标推到未来 | `schedule-time.test.ts`（3 例） |
| `UNCHANGED` 不落盘 | 工具不改状态时循环仍然 persist，白抖 mtime；现在 `UNCHANGED:` 结果不写盘 | `todo-no-write.test.ts`（内核每轮采样 mtime：重复写后不变、真改动后变大） |
| **压缩切断工具块**（P0，本轮新发现） | `tailStart` 按 token 预算切，不知道 `assistant.tool_calls` + 其 `tool` 结果是一个原子块 → 孤儿 tool 消息 → provider 400。现在边界遇到 `tool` 就回退到块首 | `context-governor.test.ts`（2 例，含 46 个 tailRatio 遍历）+ `history-invariants.test.ts`（压缩后每个请求仍合法） |
| **浏览器跨会话串页** | 浏览器是模块级单例，A 会话 navigate 会改掉 B 的页面（B 的 extract 读到 A 的内容）。现在每会话一个 target，命令与 `Page.loadEventFired` 都按 CDP sessionId 路由；删除会话时关掉它的标签页 | `browser-tools.test.ts`（2 例：两会话各自 URL/文本互不影响；关一个不影响另一个） |
| **同一会话并发 step**（P1） | 两个 `/api/agent/step` 同时跑会交错 push `messages`；scheduler 现在按会话排队，内核按路径里的 session id 加闸 | `session-lock.test.ts`（4 例）+ `SessionGateSpec.hs`（3 例） |

## 五、仍不可在本仓自动化

- MCP / LSP 真实 server（只对假服务器测协议帧）。
- 真实站点的浏览器行为（只测本地页）。
- 真模型是否遵守提示（只有真机证据）。
