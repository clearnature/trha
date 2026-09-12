# Desktop/Electron 主题进度归档（2026-09）

> 本文件为跨会话 checkpoint：汇总已完成基线（附证据指针）与待办索引，
> 供新会话加载后直接从断点继续。相关计划/分析：
> - 架构原则与决策：`docs/plan-reconciliation.md`（文末「架构原则」）+ `docs/electron-desktop-plan.md`
> - Reasonix 发布说明核对：`docs/electron-desktop-plan.md`「与 v2.11.0 核对」
> - 宿主契约：`docs/desktop-host-contract.md`（握手/租约/日志/环回门/cookie 凭证）
> - **Port 契约（UI↔后端）**：`docs/desktop-port-contract.md` ← 新增，接口/事件映射/prefs 的权威表
> - UI 移植：`docs/desktop-ui-port-plan.md`（分析+路径）+ `docs/desktop-ui-execution-plan.md`（原子+预算+状态）

## 已完成基线（M0，均带实测证据）
| 面 | 状态 | 证据/位置 |
|---|---|---|
| Electron 承载 | ✅ | Desktop=Electron 28+React（替代 Wails 背景见 Reasonix v2.11.0 说明）|
| 内核派生协议 | ✅ | scheduler `startServer`：stdout 首行 `{"v":1,"name":"trha-scheduler","port":N}`（UDS 时 port:0+socket）；日志 stderr；`TRHA_LEASE_STDIN=1` stdin 租约→exit 0（11ms 实测）|
| Desktop main 握手解析 | ✅ | `src/main/handshake.ts`（parse/isSupported，vitest 8）；版本/名称不符拒启；`before-quit` 释放租约；sandbox:true；preload 仅动词 |
| 环回与凭证 | ✅ | 默认绑定 127.0.0.1；Origin 门（跨源 403 code:origin）；会话 cookie `trha_session`（HttpOnly，写必带，401 code:session）；环回无 Origin 读放行、写需 Bearer；对外绑定零匿名放行（Scheduler 101→105 vitest 历史绿）|
| /studio 托管+版本 | ✅ | `/studio*` 静态（一条路由，不吞 API）；`/studio/versions`+`POST /studio/pin`（内存+stateDir pin.json）；桌面 renderer 产物经 `npm run export:studio` 部署为真实 SPA（相对 assets）|
| scheduler 自启入口 | ✅ | `src/cli.ts`（env 驱动；原 dist 无自启——旧 Desktop spawn 目标不起服务的 bug 已修）|
| 随包 scheduler | ✅ | `scripts/sync-scheduler.mjs`（dist+lock+`npm ci --omit=dev`）→ extraResources `resources/scheduler`（自包含，实测随包 cli 自启 health 200）|
| 随包 node | ✅ | `scripts/sync:node` → `resources/node`；实测随包 node 起随包 scheduler（零系统 node 依赖）；体积 +~122MB（win/mac 需各自平台构建机）|
| 打包 P1–P5(linux) | ✅ | electron-builder.yml（三平台契约+固定 artifactName）；产物 `trha_0.1.0_amd64.deb`；`scripts/verify-artifact.mjs` CONTRACT OK（amd64/数字属主 0-0）；P4 `studioInfo.ts` 客户端+preload getStudioInfo；P5 ci.yml desktop job（vitest run + build:main/renderer）|
| 网络经验 | ✅ | 直连 github 超时；代理 `http://127.0.0.1:10808`（记忆已存，自动使用）|

## UI 移植（M1–M3 全绿，均带实测证据）
| 里程碑 | 状态 | 证据 |
|---|---|---|
| **M1 批次1（U0 port 基建）** | ✅ | `port/`（types/port/mock/sse/http/runtime/index）+ `state/sessionStore.ts`；tdc 0 err |
| **M2 批次2（U1 壳 + U2 消息卡）** | ✅ | `ui/`（Shell/SessionContext/StatusBar/Sidebar/MessageList/Composer/PlanPrompt/SettingsPanel）、`ui/markdown.tsx`、`ui/cards/*`（User/Say/Tool/Notice/Plan/Ask）、`App.tsx` 接新壳；组件测试 44 用例 |
| **M3 批次3（U3 设置/主题/i18n + E2E + 契约）** | ✅ | `state/prefs.ts` + `ui/PrefsContext.tsx` + main `prefs.json` 原子写 IPC + preload 动词；`ui/i18n.ts`（zh/en）；global.css 新组件样式；`scripts/e2e-desktop.mjs`（`RESULT: PASS`）+ `test/e2e-protocol.test.ts`；`docs/desktop-port-contract.md` |
| 汇总验证 | ✅ | **`npx tsc --noEmit` 0 err；`npx vitest run` 22 文件 114 用例全绿**（含 E2E 协议冒烟）|

### 内核 serve 接线 ✅（本轮完成，附证据）
- `packages/app/CLI/Main.hs` 的 `runServeMode`：TODO 桩 → `API.Server.startStubKernel (configPort config)`。
- cabal 三个坑已解：`packages/app/CLI/trha-cli.cabal` 的 `name: trha` → `name: trha-cli`（消除「两包同名」）；跨包引用命名子库写法 `trha:trha-api`；`library trha-api` 加 `visibility: public`（否则报 "component is private"）。两份 cabal 的 `other-modules` 补齐 `UI.I18n/UI.SettingsView/UI.StatsView/UI.StatusInfo`。
- 验证：`KERNEL_BUILD=1 npx vitest run test/kernel-serve.test.ts`（Desktop 包内）→ **2 passed**：`trha serve` 起内核（`/health` 200、无 TODO）；完整栈 `内核 ← scheduler ← step` 返回 `[stub] …` 且含 `role:'tool'`（证明内核在答，非 echo 回落）。`cabal build all` 通过（含 trha-cli）。Desktop 全量 **24 文件 116 passed**。
- **仍是桩 adapter**（确定性两轮 tool loop，无需 key）；接真实模型需 `startServer <真实 adapter>`（`createDeepSeekProvider apiKey`）+ LLM key。
- 附带影响：`cd packages/app/CLI && cabal build` 独立构建已不成立（CLI 现依赖根包 `trha:trha-api`）；项目内 `cabal build` 正常。

未完成/顺延：
- **T5b（resume，P1）**：打开既有 sid 载入 messages（依赖 scheduler stateDir 会话恢复）。
- **GUI 级 UI 冒烟**：现 E2E 为协议级（无头环境无 Electron 宿主），需可显示环境补。
- **T12a（清理，P1）**：已 ask 用户 → **决定暂不删除，仅保留清单**（见待办 4）。

## 待办索引（按序）
1. 打包线余项：win/mac 交叉打包与签名/公证（P1-P5 win/mac 段）；deb 全量含随包产物体积确认。
2. 内核 HTTP 层事件化（G5，plan-reconciliation 遗留小项）。
3. T5b resume（桌面侧仅服务端恢复）+ GUI 级 UI 冒烟（需 Electron 宿主）。
4. **T12a 待清理（需你确认，never-delete 纪律）**——以下旧文件已被新 `ui/` 取代、当前无引用：
   - `src/renderer/components/Sidebar.tsx`（→ `ui/Sidebar.tsx`）
   - `src/renderer/components/ChatView.tsx`（→ `ui/MessageList.tsx` + `ui/Composer.tsx`）
   - `src/renderer/components/SettingsPanel.tsx`（→ `ui/SettingsPanel.tsx`）
   - `src/renderer/stores/appStore.ts`（→ `state/sessionStore.ts`；**仍被 `App.tsx` 用于 `initAPI()`**，故不能整删）
   - `src/shared/types.ts` 中 `Session/Message/Model/Tool/AgentState`（旧 UI 类型；`ElectronAPI` 仍在使用）

## 记忆要点（跨会话）
- 遵循架构原则：stdout 单行握手/日志 stderr/stdin 租约/一条 `/studio` 路由/渲染器沙盒+preload 动词。
- UI 前/后端解耦：UI 一律走 `port/` 接口（sse/http/mock），组件零直 fetch（权威契约见 `docs/desktop-port-contract.md`）。
- 删除任何旧组件前先出清单 ask（never-delete 纪律）；本档「T12a 待清理」即为该清单。
- 测试基建：组件测试用 `// @vitest-environment jsdom`（per-file），vitest include 含 `.test.tsx`；`@testing-library/jest-dom` 因 peer 冲突未装，断言用纯 `expect`。
- 断言纪律：优先显式结构断言而非 inline snapshot（避免工具改写源文件）。
