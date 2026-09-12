# Desktop UI 完整移植 — Fable5 执行计划（详细原子分裂 + 预算管理）

> 2026-09（北京时间）· 前置：`docs/desktop-ui-port-plan.md`（分析/路径/能力矩阵，本文件为可执行细化）。
> 进度归档/基线：`docs/desktop-ui-progress.md`。执行时逐原子更新本文档「状态列」并回写归档。
> 原则：每原子 = 红测 → 实现 → 绿 → 轻冒烟；验收必须可执行命令；完成声明附证据（防虚假完成）。
> 预算模型：原子按 S(≤0.5h)/M(1h)/L(2h) 估；批次预算 + 20% 风险预留；P0/P1/P2 裁剪优先级。

## 1. 目标与里程碑
- M0（已具备）：Electron 壳 + scheduler 随包/随包 node + 双模式 API + /studio 同源
- M1：`port` 门面 + sse/mock + sessionStore 重构 —— **纯前端可测、无后端依赖**
- M2：壳布局 + 会话管理 + 消息卡流（user/say 流式/tool/plan/ask/notice）—— **垂直可用**
- M3：设置接 schema + 本地 prefs、主题双套、i18n 骨架、transcript/空态、E2E

## 2. 依赖 DAG（拓扑执行序）
```
T1(port接口) ─┬→ T2(实现sse/http/mock) → T3(sessionStore) ─┬→ T5(会话管理UI) ─┬→ T8(transcript/空态)
              └→ T4(Shell) ──────────────────────────────────┤
                                                             ├→ T6(消息卡流) → T7(plan/ask卡)
                                                             └→ T9(设置面板) → T10(主题/i18n)
T2 ───────────────────────────────────────────────────────────────→ T11(E2E) → T12(清理+契约文档)
```

## 3. 原子任务表（ID · 名称 · 依赖 · 改动 · 验收 · 估时 · 风险/裁剪级）

### 批次 1 — U0 port 基建（预算 ~10h）
| ID | 原子 | 依赖 | 关键产出 | 验收（命令/断言）| 估 | 风险 | 级 |
|---|---|---|---|---|---|---|---|
| ✅ T1a | `port/port.ts` 能力子集类型 | — | `port/types.ts`(wire 形状对齐) + `port.ts`(Port 接口：modes/models/tools/sessions/step/decision/subscribe/studioVersion) | `tsc --noEmit` 0 err（顺带修复 Sidebar pre-existing 类型错）；vitest 21/21 无回归 | M | — | P0 |
| ✅ T1b | `port/mock.ts` | T1a | MockPort（内存 2 会话 fixture；subscribe/emitMock）| vitest 10（create/list/step/requireApproval/decision/subscribe/emitMock/delete）+ tsc | M | — | P0 |
| ✅ T2a | `port/sse.ts`（纯函数：normalizeEvent/consumeSse）| T1a | 事件归一化 + 流消费（分块/坏帧/中止）| vitest 6 | L | — | P0 |
| ✅ T2b | `port/http.ts` SchedulerPort（REST+subscribe 组合）| T1a/T2a | 全方法 + 统一 headers（修 request 漏 token bug）| vitest 6（stub scheduler）+ tsc | M | — | P0 |
| ✅ T2c | `port/index.ts` createPort + `port/runtime.ts`（set/get/clear）| T2a/T2b | 装配（显式 mock:false 优先于 test 默认；未配 runtime→mock+警告）| vitest 3 + tsc | S | — | P0 |
| ✅ T3a | `state/sessionStore.ts`（makeSessionStore/useMockSessionStore）| T1+T2 | 状态+动作全走 port；文本来自 step 返回值、tool/plan/decision 走 subscribe（去重设计）| vitest 8（mock 驱动：list/select/create/send/工具卡/plan+decide/错误 notice/remove）| L | — | P0 |
| ✅ T3b(调整) | appStore.initAPI 同步 setApiRuntime（port 装配共用运行时）| T3a | 启动 runtime 一致；旧 appStore 冻结，UI 引用迁移随 T4-6 新组件 | `tsc` 0 err + Desktop vitest 54/54 无回归 | L | 双通道存续至 T6 | P0 |

### 批次 2 — U1+U2 壳与消息卡（预算 ~16h）
| ID | 原子 | 依赖 | 产出 | 验收 | 估 | 风险 | 级 |
|---|---|---|---|---|---|---|---|
| ✅ T4a | `ui/Shell.tsx` 布局（侧栏+主区+底栏）| T3b | `ui/Shell.tsx`（三区插槽）+ `ui/SessionContext.tsx`（Provider/useSession/默认 store）+ store 目录字段与 loadCatalog | ui-shell 4/4（三区/无 statusBar 省略/注入/无 provider 回退）+ `tsc` 0 err | M | — | P0 |
| ✅ T4b | 底部状态行（模型/会话/usage 占位）→ 接 port.usage/version | T4a | `ui/StatusBar.tsx`（mode/短 id/busy/error/usage 占位/版本）+ `loadVersion` | ui-status-bar 4/4 | S | — | P0 |
| ✅ T5a | 会话列表 UI（新建/列表/选中/删除/续聊 sid）| T4a | `ui/Sidebar.tsx`（会话操作 + mode 选择 + tools/models 面板）| ui-sidebar 5/5；**顺带修 MockPort nextId 与 fixture ID 冲突真 bug** | M | — | P0 |
| T5b | resume（本地 transcript?桌面侧仅服务端恢复——scheduler stateDir 会话）| T5a | 打开既有 sid 载入 messages | E2E(随包链) 冒烟 | M | 服务端恢复依赖 | P1 |
| ✅ T6a | `ui/cards/UserCard.tsx` + `SayCard`（流式+markdown 轻渲染）| T3a | `ui/markdown.tsx`（无依赖、React 节点渲染防注入）+ UserCard/SayCard | ui-cards 7/7（标题/列表/段落、fenced code、inline code+bold、HTML 不注入、流式光标）| M | — | P0 |
| ✅ T6b | `ui/cards/ToolCard.tsx`（名称/参数/状态/耗时/输出折叠）| T3a | `ui/cards/ToolCard.tsx` | ui-tool-card 5/5（含 running→succeeded 序列）| M | — | P0 |
| ✅ T6c | `ui/cards/NoticeCard`（错误/系统）| T3a | `ui/cards/NoticeCard.tsx`（tone: error/info/system）| ui-notice-card 3/3 | S | — | P0 |
| ✅ T7a | PlanCard（approve/deny 动词→decision API）| T6c | `ui/cards/PlanCard.tsx` + `ui/PlanPrompt.tsx`（接 store.decide）| ui-plan-card 6/6（纯组件 3 + mock roundtrip 3）| M | — | P1 |
| ✅ T7b | AskCard（未来 ask 能力占位；无 ask 时隐藏）| T6c | `ui/cards/AskCard.tsx`（available=false 隐藏/禁用）| ui-ask-card 2/2 | S | 依赖内核 ask | P2 |
| ✅ T8a | Transcript 只读视图（messages 回放）+ 空态/欢迎文案 | T5b | `ui/MessageList.tsx`（UiMessage→卡映射+空态）+ `ui/Composer.tsx` + `App.tsx` 接新壳 + SettingsPanel 切 sessionStore | ui-message-list 8/8；全量 19 文件 99/99 | M | — | P1 |

### 批次 3 — U3+U4（预算 ~10h）
| ID | 原子 | 依赖 | 产出 | 验收 | 估 | 风险 | 级 |
|---|---|---|---|---|---|---|---|
| ✅ T9a | SettingsPanel 接 schema（本地 prefs：theme/lang/字号 + 后端只读面：版本/pin 显示）| T4a | `ui/SettingsPanel.tsx`（本地 prefs + mode 详情/模式/模型/版本+pin）| ui-settings-panel 4/4（渲染/persist theme/persist 字号/切语言）| M | — | P0 |
| ✅ T9b | 本地 prefs 持久化（localStorage/文件经 preload 动词）| T9a | `state/prefs.ts`（normalizePrefs + backend 抽象）+ main `prefs.json` 原子写 IPC + preload 动词 | prefs 7/7（往返/非法回退/electron 委托）+ tsc | M | — | P1 |
| ✅ T10a | 主题双套（沿用 tokyo/light 色板映射 CSS 变量）| T9a | global.css 新组件样式段 + prefs→documentRoot（data-theme/fontSize/lang）| 全量 22 文件 114/114 + tsc 0 err | M | win/mac 视觉待人工 | P1 |
| ✅ T10b | i18n 骨架（zh/en 键集：壳/卡/状态行文案）| T4a | `ui/i18n.ts`（键集+插值）+ 壳/卡/状态行接 `useT()` | i18n 4/4（键覆盖/插值/回退）+ 组件文案断言改中文全绿 | M | — | P1 |
| ✅ T11 | E2E 冒烟脚本（随包链：scheduler 起 → UI 建会话/发消息/收卡→断言）| 批次2 完成 | `scripts/e2e-desktop.mjs` + `test/e2e-protocol.test.ts`（CI 覆盖）| `RESULT: PASS`（握手/health/modes/models/读放行200/写401/session CRUD/租约 exit 0）| L | GUI 级待 Electron 宿主 | P0(收口) |
| T12a | 清理：删除直 fetch 旧路径/未用组件 | 全 | diff 干净 | `tsc`+全量 vitest 绿 | S | **删除需用户确认清单（见 progress 待办 4）** | P1 |
| ✅ T12b | 契约文档：port 接口表 + 事件→卡映射表 + 本计划状态 | 全 | `docs/desktop-port-contract.md` | 文档与代码 grep 一致（12 方法/11 端点/12 ui 文件）| S | — | P1 |

## 4. 预算管理
### 4.1 批次预算与分配
| 批次 | 预算(h) | 分配 | 里程碑出口（证据）|
|---|---|---|---|
| 批次1 U0 | 10（T1-3 估 9 + 预留1）| 测试/修复 ~35% | ✅ M1（54/54 vitest + tsc 0 err）|
| 批次2 U1+U2 | 16（估 14.5 + 预留 1.5）| 测试 ~30% | ✅ M2（22 文件 114 vitest + E2E RESULT: PASS；T5b 顺延）|
| 批次3 U3+U4 | 10（估 8.5+预留1.5）| 测试 ~30% | ✅ M3（prefs 往返 + i18n 键覆盖 + E2E 协议冒烟输出；GUI 冒烟待宿主）|
| **合计** | **36h**（≈9 个 4h 会话；+20% 预留≈43h 上限）|

### 4.2 规则
- 每会话建议 1 批次内的 2–4 原子；批间设 **checkpoint**（更新本文档状态列 + 记忆）。
- 裁剪规则：预算超 120% → 按 P 级裁剪（先 P2：T7b/T10b 可后置；再 P1）；**P0 恒做**。
- 测试预算独立于实现（红→绿），不计入"溢出"；E2E 若受无头 GUI 阻塞 → 降级为协议级脚本（scheduler 起+HTTP 断言）+ 标注待 GUI。
- 并行窗口：批次1 内 T4a 可旁路（不依赖 store 的静态壳）与 T2 并行——仅在人力允许时。

## 5. 节奏与对抗自检
- 每原子：写断言→红→实现→绿→（UI 原子加快照）→轻冒烟；失败照 Fable5 递归修正（日志→根因→修→重测）。
- 对抗视角重点：T3a 流式竞态（chunk 顺序/断流）、T2a SSE 重连/会话不存在、T9a 前后端设置面边界混淆。
- 防虚假完成：每个原子完成声明必须带（命令 + 输出/文件 diff）证据，记录于本表状态。

## 6. 状态列（执行时逐原子勾选）
批次1：✅T1a ✅T1b ✅T2a ✅T2b ✅T2c ✅T3a ✅T3b(调整版)
批次2：✅T4a ✅T4b ✅T5a T5b▢ ✅T6a ✅T6b ✅T6c ✅T7a ✅T7b ✅T8a
批次3：✅T9a ✅T9b ✅T10a ✅T10b ✅T11 T12a(用户决定暂不删除，清单保留) ✅T12b
