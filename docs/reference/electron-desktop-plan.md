# Electron 桌面壳对齐计划（替代 Wails 的跨平台渲染方案）

> 2026-09（北京时间）。背景：DeepSeek-Reasonix-studio 桌面端使用 Wails 并在
> Windows/跨平台渲染上出问题（见其 `DESKTOP_CRASH_DIAGNOSTICS_RUNBOOK`，多处
> “Wails 启动前”生命周期限制）——因此桌面方案改为 **Electron**。
> trha `packages/app/Desktop` 已是 Electron 28 + React；本计划把它的宿主协议与
> 你裁定的架构原则（见 `docs/plans/plan-reconciliation.md` 文末「架构原则」）对齐。
> 参照：`/home/yanli/work/DeepSeek-Reasonix-studio-v2.11.0/docs/DESKTOP_HOOKS.zh-CN.md`
> （stdout/stderr 捕获与特殊 stdout 语义，作为桌面↔子进程约定参照）。

## 架构原则（复述，执行不得违反）
1. 内核/编排由外壳派生；**stdout 首行 = 一行版本化 JSON 握手**；版本不识即拒启；日志一律 stderr。
2. **stdin = 租约**：父进程一旦关闭（崩溃或正常退出）→ 子进程排空退出；三平台不依赖信号。
3. 页面路由一条规则（`/_studio/` 前缀 → 页面，其余落内核 API）；不做“内核枚举全部路由”。
4. 渲染器沙盒化、上下文隔离、无 node；preload 只递出动词。

## 现状（已盘点，2026-09）
- Desktop：Electron `^28.3.3`，main 已 spawn 编排（`scheduler/dist/Server/index.js`）并以文本
  “listening” 探测就绪；preload 暴露 `getToken/getSchedulerPort/getAppVersion/platform`；
  `contextIsolation:true`、`nodeIntegration:false`；**缺** `sandbox:true`、握手/租约/日志 stderr 化。
- 编排端 **E1 已完成并实测**：`startServer` stdout 仅一行 `{"v":1,"name":"trha-scheduler","port":N}`；
  日志转 stderr；`TRHA_LEASE_STDIN=1` 时 stdin `end/close` → exit 0（租约释放 11ms）。

## 执行计划（E2 原子分解，TDD）

| # | 任务 | 验收 |
|---|---|---|
| ✅ E2-1 | main 握手解析纯模块 `src/main/handshake.ts`：`parseHandshake(line)` + `isSupported` | vitest 8/8（合法/空白/日志行非握手/坏 JSON/缺字段/版本≠1/名称不符）|
| ✅ E2-2 | `startScheduler` 改造：首行握手解析 → 版本/名称校验拒启；stderr 转发；`before-quit` 释放 stdin 租约（kill 兜底 3s）；`sandbox:true`；路径可 `TRHA_SCHEDULER_PATH` 覆盖 | main tsc 通过；Desktop vitest 14/14 |
| ✅ E2-3 | preload 动词面核对：仅 getToken/getSchedulerPort/getAppVersion + 只读 platform（无多余能力面）| 检查清单已核 |
| ✅ E2-4 | `docs/contracts/desktop-host-contract.md` 已产出（握手/租约/日志/安全基线 + Reasonix hooks 差异对照）| 文档存在 |
| 🟡 E2-5 | 协议端已实测（E1：spawn 编排 → 握手 v1 → 关 stdin exit 0/11ms）；Desktop 内真实 GUI 冒烟待有显示环境 | 待 GUI 环境运行 `npm start` |

## 不做（本期范围外）
- React 渲染 UI 全量重做、`/_studio/` 页面路由（renderer 层后续）；Reasonix hooks 事件注入语义
  （PostLLMCall/SessionStart 特殊 stdout）——仅记入 E2-4 契约差异。
- 打包/签名/自动更新。

## 风险
- Electron 无头 CI 跑 GUI 有限——E2-5 用纯 Node spawn 子进程脚本验证宿主协议（不依赖窗口）。
- 编排 dist 路径引用（`../../../../scheduler/dist/...`）在打包后变化——E2-2 同时把路径改为可配置
  `env.TRHA_SCHEDULER_PATH` 回退相对路径（dev 用）。

## 与 Reasonix Studio v2.11.0 发布说明核对（2026-09）

来源：`docs/reference/Electron 外壳.txt`（Reasonix Studio v2.11.0 pre-release 说明，含 Wails→Electron 迁移背景）。

| Reasonix 表述 | trha 状态 |
|---|---|
| 外壳改由 Electron 承载（Wails 渲染/资源服务器问题）| ✅ 一致：Desktop 已是 Electron 28；E1/E2 落地 |
| 内核派生：stdout 一行版本化 JSON 握手、不识拒启、日志 stderr | ✅ E1（scheduler）+ E2-1/2（main 解析拒启）实测 |
| stdin 租约（父关即排空；三平台无信号）| ✅ E1（`TRHA_LEASE_STDIN` end→exit 0）+ E2-2（before-quit 释放）|
| 环回 HTTP + 原点门（无原点读放行/写拒绝；凭证仅 cookie）| 🟡 部分修复：scheduler 默认绑定 `127.0.0.1`（可 `host` 覆盖），实测仅环回监听；**无“原点”引用门/写拒绝与 cookie 凭证**——本地静态 token 场景风险低，记录差异待后续 |
| `/_studio/` 一条路由（拒绝“内核枚举路由剩落页面”）| ✅（2026-09）：scheduler 环回托管 `studio-public/`（`/studio*`→静态，其余 API）；真实 SPA 接入待凭证策略 |
| 渲染器沙盒/上下文隔离/无 node；preload 只递动词 | ✅ E2-3（sandbox:true、contextIsolation、动词面）|
| `GET /studio/versions`+`POST /studio/pin`（版本面板/锁定）| ✅：versions（current/pinned）与 pin（内存+stateDir pin.json 持久化）|
| 服务 `POST /plan-decision`（审批=整个结果、409/带码拒绝、封存）| 🟡 差异：trha plan 裁决在编排 `/api/session/:id/decision`（bool approve/deny）+ CLI plan 流；无 409 带码与“封存不改删”语义——G1 已裁审批归编排，此语义差异记录不移植 |
| 单数据主目录单实例（instanceid 锁）| ❌ 未做（多实例写者分叉风险在 trha 由 CLI transcript+会话 id 缓解；桌面多窗口阶段再考虑）|
| electron-builder：x64↔amd64 契约、CI 三平台、签名/公证线 | ❌ 未做打包线（记录为发布线任务）|

## 打包线（electron-builder 契约，规划未执行 —— 待另会话）

执行进度（2026-09，经代理 127.0.0.1:10808 打通 github 下载）：

| # | 项 | 验收（执行时）|
|---|---|---|
| ✅ P1 | `electron-builder` 配置（Desktop）：win nsis（按用户安装、接管旧 Wails 安装需卸载一次确认）/ mac dmg+pkg（公证/钉封、健康见证）/ linux deb（包名与旧包一致=升级）| 三平台配置产物命名沿用既有标识（改名=发布没人收的版本）|
| ✅ P2 | 架构映射契约：x64↔amd64（node arch → 发布 arch，未知抛）；`scripts/verify-artifact.mjs` 真包回读 |
| ✅ P3(linux) | 真包回读：`trha_0.1.0_amd64.deb`（Package=trha/Version/Architecture=amd64；owner 按数字 0/0 断言——Reasonix 的 root/root 显示坑）；win/mac 签名公证线待 CI |
| ✅ P4(客户端) | `src/main/studioInfo.ts` fetch `/studio/versions`（current/pinned）+ main 启动取版本 + preload `getStudioInfo` 动词（3 测试）；自更新事务/健康见证待发布线 |
| ✅ P5(linux job) | ci.yml 新增 `desktop` job（vitest + build:main/renderer，Node 20）；win/mac 三平台作业属发布线另配 |

依赖：内核/编排二进制随包（trha-kernel 当前为源码/脚本形态，需先固化内核产物；注意"只签外容器层，安装后内核未签名运行"的 Windows 契约）。

> 产物：`release/linux-unpacked/trha`（177MB）与 `release/trha_0.1.0_amd64.deb`（73.7MB）；
> 构建需代理（本机网络直连 github 超时；`HTTP_PROXY=http://127.0.0.1:10808` 生效）。
> 内核随包（2026-09 已解决，Linux 线）：`sync-scheduler`（dist+lock+`npm ci --omit=dev`→resources/scheduler-dist）+
> `extraResources`（scheduler → resources/scheduler）；补 CLI 自启动入口 `scheduler/src/cli.ts`（原 dist 无自启——
> Desktop 旧 spawn 目标不起服务，已修）；随包 node（`sync:node` 拷系统 node → resources/node）→
> **打包产物零系统 node 依赖**（实测：resources/node/node 起 resources/scheduler/cli.js → 握手+health 200）。
> 体积影响：unpacked node 占 ~122MB；deb 增大相应（electron-builder filter ['*'] 单文件）。
> win/mac：随包 node 需各自平台构建机提供（script 自动取 `which node`），本机未交叉验证。
