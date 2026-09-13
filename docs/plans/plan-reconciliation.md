# 计划 vs 现实对账（plan-reconciliation）

> 2026-09（北京时间）。把 `docs/` 各计划文档的编号项与当前代码逐一核对，
> 判定：✅ 已实现（含证据）｜🟡 由下游/方案变更实现（语义转移）｜❌ 真缺口。
> 核对证据 = 命令实测 + 文件位置。行动清单在文末（真缺口，未实施）。

## 来源文档与处置建议

| 文档 | 性质 | 处置 |
|---|---|---|
| implementation-plan-cli-tui.md | 活计划（L0→L3）| 保留；下表对齐，缺口列入行动 |
| implementation-plan-phase2.md | S0-S3（旧，2026-09 实测版）| 保留；S0 语义已由 K 系列闭环 |
| plan-phase2-s2-s3-atomic.md | S2/S3 原子分解（旧）| 可归档（项已在下游实现）|
| kernel-tool-execution-plan.md | 方案 A/B（已选 A 并执行完 K1–K6）| 可标注完成 |
| implementation-roadmap.md | 12 周周计划（早期构想）| 与实施分叉严重，建议重写或归档 |
| implementation-plan-shell-sharing.md / shell-sharing-design.md / protocol-shell-kernel.md | 共享协议设计 | protocol 总账保留；shell 设计已由编排接管 |

## 逐项核对

### Phase1 L0（cli-tui 计划）
| 项 | 状态 | 证据 |
|---|---|---|
| P1.1 Markdown 渲染 | ✅ | `UI/Render/Markdown.hs` + hspec |
| P1.2 Tool 调用卡 | ✅ | `UI/Render/ToolCard.hs` + hspec |
| P1.3 Quick Picker | ✅ | `UI/Render/Picker.hs`；TUI `/` 菜单面板（后续增强）|
| P1.4 消息区组件化 | ✅ | drawMessages/drawMessage/drawPending 统一 widget |
| P1.5 状态页脚+主题 | ✅ | `UI/Theme.hs`（dark/light）、`UI/Render/Footer.hs`；P1.5 后扩展为可配置 metrics |
| P1.6 命令注册表共享 | ✅ | `UI/Commands/Registry.hs` 单一来源（REPL+TUI+picker+补全）|

### Phase2 L1（S0–S3）
| 项 | 状态 | 证据 / 说明 |
|---|---|---|
| S0 协议闭环 | ✅（方案转移）| 内核 OpenAI `/v1/chat/completions`(tools) + TS 桥 + CLI 三链端到端（K6）；protocol-shell-kernel.md 总账 |
| S1 plan/approval | ✅（架构定位：编排层）| 统一 `/api/agent/step`（`requireApproval: true` → awaiting_approval）+ `/api/session/:id/decision`；CLI `/plan` + TUI plan card（agent:plan/decision 事件）；**内核(Haskell)侧 Plan 状态机/servant 回合屏障未实现**（`API/Server.hs` 无 plan，grep 空）→ 若按原 L1 语义为缺口 |
| S2 tool 事件详情 | ✅（下游实现）| ToolEvent running/succeeded/failed+durationMs；tool:update SSE；transcript tool；ToolCard 状态色 |
| S3 session 恢复 | ✅（G2 后）| CLI/TUI resume ✅ + 服务端持久化（`stateDir` 原子 JSON + 启动载入 + 删除清理，E2E 重启续步）|

### Phase3 插件化 + 三端
| 项 | 状态 | 证据 |
|---|---|---|
| P3-0 协议总账 | ✅ | docs/contracts/protocol-shell-kernel.md |
| P3-1 PluginManager 运行时 | ✅ | ServerConfig.plugins + 钩子 + GET /api/plugins |
| P3-2/3 契约测试 | ✅ | plugins-runtime（TS 89/89 内）|
| P3-4/5 动态插件管理 | ✅ | POST/DELETE /api/plugins（409/404）|
| C1 ctx/effect 重构 | ✅ | PluginContext activate/deactivate + ctx.on 可逆订阅 |
| A1 插件目录加载器 | ✅ | src/Plugins/loader.ts；后续热重载 watcher（watchPlugins）|
| 外壳 /plugins 视图 | ✅ | CLI `/plugins`（列编排插件）|
| **Cordis 服务化深化** | ✅（本会话新增，超出原清单）| registry/inject/waterfall/bail/parallel/serial/能力面/热载（docs/cordis-plugin-notes.md）|
| **trha-ui 共享渲染库** | ❌ | 未做（渲染仍在 CLI 包内）|
| **Desktop/Web 起跑基线** | ❌ | packages/app/Desktop 仅有 README+旧 dist；Web 为空壳 |

### 内核深化（kernel-tool-execution-plan 方案 A）
| 项 | 状态 |
|---|---|
| K1–K6（协议扩展/桥/工具循环/内核 stub/三链 E2E）| ✅ 全部（主线证据：真模型/0.8B 端到端、C 系列测试）|

## 真缺口（行动清单，未实施）

| # | 缺口 | 规模 | 备注 |
|---|---|---|---|
| ~~G1~~ 内核（Haskell）Plan 状态机 + 回合屏障端点 | **关闭（架构决策，2026-09）** | 理由见下「架构原则」；S1 标注为“由编排层实现” |
| ~~G2~~ 服务端会话持久化 + 恢复端点 | ✅（2026-09 完成）| `stateStore.ts` 原子写 + `stateDir` 启动恢复；store 单测 5 + E2E 双实例恢复续步（TS 94/94）|
| G3 | 三端共享：Haskell `trha-ui` 渲染库提取 | 大 | Phase3 原目标；Desktop/Web 尚无真代码 |
| G4 | Desktop/Web 起跑基线（三端协议共享验证）| 大 | 依赖 G3 |
| G5 | 内核 HTTP 请求纳入事件矩阵（遥测）| 小 | agent-lifecycle-notes 已标注缺口 |

## 建议
- G1：已裁决**关闭**（架构原则见文末）——L1 plan/approval 定位为编排层职责。
- G2：✅ 已完成（stateDir 持久化，见上）。
- G5：规模小、收益实，建议优先。
- G3/G4：Phase3 三端大项，另开会话规划（Electron 起跑架构原则见文末，来自用户 2026-09 裁定）。

## 架构原则（内核/外壳职责分界，2026-09 用户裁定）

- **内核 = 无状态协议/执行引擎**：模型请求-响应 + 工具执行输入输出；不持用户决策态。
- **回合屏障/审批（plan/approval）= 外壳-编排层职责**：UI 决策门、会话态、恢复都属于外壳与编排；
  因此 G1（内核 Plan 状态机）**关闭**——放进内核会模糊“模型引擎 vs 交互裁决”的分界。
- Electron 外壳（G3/G4 起步时的架构指引，来自项目宿主设计）：
  - 内核由外壳派生：stdout 首行**一行版本化 JSON 握手**（版本不识即拒启），日志一律 stderr；
  - stdin 为**租约**（父进程一旦关闭 → 内核排空退出；覆盖崩溃与正常退出，三平台不依赖信号）；
  - 页面路由一条规则（`/_studio/` 前缀 → 页面，其余落内核 API）——**不做**“内核枚举全部路由、剩下落页面”（那是资源服务器形状，内核每加路由要改一次）；
  - 渲染器：沙盒化、上下文隔离、无 node；preload 只递出动词（最小消息面）。
