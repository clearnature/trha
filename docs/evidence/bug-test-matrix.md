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

## 四、已知未覆盖（后续）

- provider 超时/中断：没有用例（`streamPostSse` 的 20s 超时未测）。
- 多智能体真实并发：只测桩（父子、深度上限），无并发压力。
- 调度跨天/时区：只测 `at` 到点。
- `todo_write` UNCHANGED 时的"不落盘"只测了状态对象不变，没比对 mtime。
