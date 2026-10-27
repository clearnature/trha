# trha 当前架构快照（2026-10-27）

> **日期**：2026-10-27（北京时间）
> **性质**：**实测快照**（代码结构 + 运行时监听面），不是设计稿。
> **用途**：新人/新会话先看这一份建立全貌；要查「为什么这样设计」看意图文档，要查「与参考实现的差距」看对照评审。
>
> **与其它文档的分工**：
>
> | 文档 | 回答什么 | 性质 |
> |---|---|---|
> | 本文 `architecture-snapshot-2026-10-27.md` | **现在长什么样**：分层、模块、数据流、问题索引 | 结构事实（实测） |
> | `architecture.md` | 早期设计：微内核、Free monad、分层规划 | 设计稿（§6 包结构与现状不符） |
> | `architecture-intended-vs-actual.md` | **意图 vs 现状**：D-1…D-9、状态分档 | 自评 |
> | `../reference/trha-architecture-review.md` | 构建拓扑实测（S1–S6） | 外部复核 |
> | `../reference/trha-architecture-benchmark-review.md` | 对照 dsh / Reasonix / opencode 的架构形状（A1–A8） | 对照评审 |
>
> 本文的问题编号（S/C/D）与对照评审的 A 编号互为索引，不重复证据细节。

---

## 0. 一页图

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ L3 外壳 Shells —— 只做输入/渲染，不做业务裁决                                 │
│                                                                              │
│  CLI / TUI  (Haskell, packages/app/CLI, 118 文件 / 19.3k 行)                  │
│   ├─ Main.hs            tui / cli / serve 三个子命令                          │
│   ├─ Bridge/Scheduler   HTTP + SSE 客户端（唯一后端入口）                      │
│   ├─ Core/              HTTP · SSE · Transcript · PlanStore · RunLog ·        │
│   │                     Memory · StatePaths · SessionSummary · Replay         │
│   └─ UI/                Brick · Commands(Registry) · Render(Markdown/ToolCard/│
│                         Diff/Footer/Sidebar/Picker) · Theme · StatusInfo      │
│                                                                              │
│  Desktop (Electron, 72 文件 / 7.2k 行)                                        │
│   ├─ main/              handshake · studioInfo（派生 scheduler、租约、握手）   │
│   ├─ preload/           只递出动词（contextIsolation，无 node）                │
│   └─ renderer/port/     http · sse · mock · provider · runtime（Port 契约）    │
│                                                                              │
│  Web (React, 17 文件 / 1.6k 行) —— stores · sse · layout（dist 被 /studio 托管）│
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ HTTPS + Bearer（默认自签；loopback 跳过校验）
                                │ /api/agent/step · /api/events/:id(SSE) · /api/session/*
┌───────────────────────────────▼──────────────────────────────────────────────┐
│ L2 编排 Orchestration (TS scheduler, :28433, 46 文件 / 9.8k 行)                │
│                                                                              │
│  Server/index.ts（Express）                                                   │
│   ├─ 会话面    /api/session/start · /api/sessions · /:id[/messages|mode|plan]  │
│   ├─ 执行面    /api/agent/step · /decision · /interrupt · /step-result        │
│   ├─ 能力面    /api/tools · /providers* · /models · /plugins · /mcp|/lsp      │
│   ├─ 事件面    /api/events/:id（SSE，白名单转发 4 类）                         │
│   ├─ 协议面    /v1/{models,chat/completions,messages}（对外代理）              │
│   └─ 页面面    /studio/*（托管 Web dist）                                      │
│                                                                              │
│  runStep 主循环                                                               │
│    agent:step:before(bail) → agent:tools(waterfall) → contextGovernor →        │
│    Bridge → 模型回复 → 工具执行 → 下一轮（maxToolRounds）                      │
│                                                                              │
│  Bridge/Haskell.ts     HTTP + SSE → 内核（这一跳是**明文 HTTP**）              │
│  工具面  standardTools · extraTools · browser · lsp · mcp · skills · transcribe│
│          toolCatalog(schema 单一来源) · toolGuard(confineWritePath)            │
│  会话面  stateStore(JSON 原子写) · sessionLock · fileHistory · permission      │
│  扩展面  Plugins(loader/registry/watcher) · Subagent(Manager/Parallel)         │
│  基建    tls · env · retry · balance · contextGovernor                        │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ HTTP（:19433，两边默认一致）
                                │ /agent/step · /session/* · /providers* · /v1/*
┌───────────────────────────────▼──────────────────────────────────────────────┐
│ L1 内核 Kernel (Haskell, :19433, 5 个 cabal library)                          │
│                                                                              │
│  API (Servant)                                                                │
│   ├─ /session/* · /agent/step · /providers/*                                  │
│   └─ 三 wire：OpenAI / Anthropic / Responses（± 流式，Raw SSE）                │
│  Core                                                                         │
│   ├─ Session    eventLog · projections · agentState · plan                    │
│   ├─ Agent      StateMachine · Modes                                          │
│   ├─ Event Bus · Tools Registry · Provider Types · Cache                      │
│   └─ Plugin†    Free-monad（**生产代码未接线**，仅测试引用）                    │
│  LLM            Adapter · Providers(OpenAI/DeepSeek/…) · Stream               │
│  Infrastructure CPU(30 模块：三值/GF27/AVX2) · WebGPU(9 模块+FFI)              │
│                 Storage(JSON/SessionStore/SQLite) · Network · Sandbox · Telemetry│
│  Kernel/Carrier                                                               │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ HTTPS（外部 API）或本地计算
                        ┌───────▼────────┐
                        │ Provider       │ DeepSeek/OpenAI/… ｜ 本地 CPU/WebGPU
                        └────────────────┘

L0 规范基座（仓外）：Agda「律算合一」+ pyBitNet《架构宪法》—— 只作对拍权威，不参与本仓构建
```

---

## 1. 分层细分

### L0 规范基座（仓外）

| 项 | 内容 | 与本仓关系 |
|---|---|---|
| Agda 规范 | `/data/work/discrete-mathematics` | 对拍权威；`test/cpu/Spec.hs` 引用 17 处；**不参与构建** |
| pyBitNet《架构宪法》 | `/data/trit/pyBitNet` | 设计约束来源；不参与构建 |

### L1 内核（Haskell，5 个 library）

| 子层 | 模块 | 职责 | 规模 |
|---|---|---|---|
| API | `src/api/API/Server.hs` `ProviderRuntime.hs` `Providers.hs` `ProviderProbe.hs` | Servant 路由；三 wire（OpenAI/Anthropic/Responses）± 流式；provider 注册表 | 4 文件 / 3.0k 行 |
| Core | `Core/Session` `Core/Agent` `Core/Event` `Core/Tools` `Core/Provider` `Core/Cache` | 会话事件日志与投影、FSM、事件总线、工具类型与注册表、provider 类型 | 13 文件 / 1.8k 行（`Core.Plugin` 已归档；`Core.HTTPProxy` 移到 infra） |
| LLM | `src/llm/LLM/{Adapter,Providers,Stream}` | 模型适配与流式聚合 | 5 文件 / 1.4k 行 |
| Infrastructure | `CPU/` 30 模块、`WebGPU/` 9 模块 + `Raw/` FFI、`Storage` `Network` `Sandbox` `Telemetry` | 本地三值推理、GPU 后端、持久化、HTTP、沙箱、遥测 | 43 文件 / 7.0k 行 |
| Kernel | `src/Kernel/Carrier.hs` | 推理载体 | 1 文件 |

**内核 API 端点在代码中的分组**（`src/api/API/Server.hs` Servant 类型）：

```
/session/start · /sessions · /session/:id · /session/:id/messages · /session/:id/delete
/session/:id/approval · /session/:id/decision · /session/:id/plan(±POST) · /session/:id/step-result
/agent/step
/providers · /providers/{protocols,probe,check,edit,websearch,thinking,in-use,remove}
/v1/models · /v1/chat/completions · /v1/messages · /v1/responses
/v1/{chat/completions,messages,responses}/stream   ← Raw SSE
```

### L2 编排（TypeScript，scheduler）

| 子层 | 模块 | 职责 |
|---|---|---|
| Server | `Server/index.ts`（2.6k+ 行）+ `stateStore` `sessionLock` `contextGovernor` | 全部 HTTP 路由、会话存储、上下文治理 |
| 执行 | `runStep` 主循环（bail → waterfall → 治理 → Bridge → 工具 → 下一轮） | turn 编排、工具循环、审批挂起 |
| 工具 | `standardTools` `extraTools` `browser` `lsp` `mcp` `skills` `transcribe` `toolCatalog` `toolGuard` | 工具实现与 schema 单一来源；写入围栏 |
| 桥 | `Bridge/Haskell.ts` | 到内核的 HTTP/SSE（明文这一跳） |
| 扩展 | `Plugins/{loader,Plugin,Registry,watcher}` `Subagent/{Manager,index}` `Parallel/Scheduler` | Cordis 式插件、子代理、并行调度 |
| 权限 | `Permission/{modes,permissionRules}` | 模式与规则 |
| 基建 | `tls` `env` `retry` `balance` | TLS、环境、重试、余额 |

### L3 外壳

| 壳 | 技术 | 入口 | 与后端的关系 |
|---|---|---|---|
| CLI / TUI | Haskell + brick/vty/haskeline | `Main.hs`：`tui` / `cli` / `serve` | 只经 `Bridge/Scheduler` 连 :28433；`serve` 在**本进程**起内核 |
| Desktop | Electron 44 + React 18 | `src/main`（派生 scheduler、握手、租约） | 渲染进程只经 `renderer/port/*`，不直接 fetch |
| Web | React + Vite | `src/stores` `src/layout/sse.ts` | 由 scheduler 以 `/studio` 托管（同源） |

**三壳共享的是调度器与配置，不是代码**：CLI 用 Haskell 重写了一份 Port 层（`Bridge/Scheduler.hs`），
Desktop 用 TS（`renderer/port/*`），Web 用 `stores` + `EventSource`。

---

## 2. 一次 turn 的数据流

```
用户输入
  │
  ├─ CLI/TUI ──POST /api/agent/step──┐
  ├─ Desktop（Port.http）────────────┤
  └─ Web（fetch）────────────────────┤
                                     ▼
                        scheduler runStep
                          ├─ plugins.runBail('agent:step:before')
                          ├─ plugins.service('tools').list() → waterfall('agent:tools')
                          ├─ contextGovernor.govern(messages)
                          ├─ repairToolPairs → withSystemPrompt
                          ├─ bridge.queryModelStream → 内核 /agent/step
                          │     ├─ FSM 屏障（pending approval / planning → 409）
                          │     ├─ llmChat adapter → 外部 API 或本地 CPU/WebGPU
                          │     ├─ verdictOfWithState → 约束判定（D-3 投影）
                          │     └─ appendEvent + persistStep（内核 checkpoint）
                          ├─ 回复 / tool_calls → executeTool（toolGuard）
                          └─ 下一轮（≤ maxToolRounds）
                                     │
        SSE /api/events/:id ─────────┘
          agent:message · tool:update · agent:delta · plan/decision
                                     ▼
                        壳渲染（Markdown / ToolCard / 计划卡）
```

**关键契约**：

| 项 | 值 | 出处 |
|---|---|---|
| 壳 → 编排 | HTTPS + `Authorization: Bearer <TRHA_TOKEN|dev-token>` | `contracts/protocol-shell-kernel.md` |
| 编排 → 内核 | **明文 HTTP + `Bearer <kernel-token>`**（Host/Origin/JSON 门控） | `Core/KernelToken.ts`、`Bridge/Haskell.ts`、`API/Security.hs` |
| 内核监听 | **`127.0.0.1`（loopback only）** —— 2026-10-27 修复；此前 `Warp.run` 默认绑 `0.0.0.0` | `src/api/API/Server.hs`（`kernelBindAddress` / `kernelSettings`） |
| 证书 | `~/.trha/tls/{cert,key}.pem` 自签，SAN localhost/127.0.0.1 | `Server/tls.ts` |
| 端口默认 | scheduler `28433`；内核 CLI `19433`、scheduler 默认 `19433`（2026-10-27 起，两边一致） | `cli.ts:14`、`Args.hs:103`、`index.ts:77` |
| 运行文件 | `~/.trha/run/{kernel,scheduler}.pid`（0600）；`trha status` / `trha stop` 读取；停止前校验 `/proc/<pid>/cmdline` | `Core/RunState.hs`、`scheduler/src/core/Core/RunPid.ts` |

---

## 3. 问题索引

### 3.1 结构性问题（S）

| # | 问题 | 证据 | 对照评审 |
|---|---|---|---|
| **S1** | 内核已绑 **`127.0.0.1`** 并加 **loopback gate**（**per-launch** Bearer token + Host/Origin + 非 JSON 写 415），2026-10-27 修复；此前 `0.0.0.0` 且无认证 | `src/api/API/Security.hs`、`~/.trha/kernel-token`(0600，每次启动轮换)、`ss` 应为 `127.0.0.1:19433` | A2 |
| **S2** | 同一事实存**三份**（内核 `Session` / scheduler `PersistedSession` / CLI `transcript.jsonl`），无权威声明 | `Core/Session/Types.hs:74-109`、`stateStore.ts:25-51`、`Core/Transcript.hs:82-88` | A1 |
| **S3** | 审批/计划**两条权威**（内核 FSM + scheduler `pendingApproval` 降级），且文档自相矛盾 | `Core/Session/Manager.hs:107-203`、`API/Server.hs:203-213`、`plans/plan-reconciliation.md` | A4 |

### 3.2 一致性问题（C）

| # | 问题 | 证据 |
|---|---|---|
| **C1** | ~~「微内核 / 一切皆插件」名实不符~~ **已归档（2026-10-27）**：`Core.Plugin` + `PluginSpec` 移到 `archive/haskell-plugin/`，文档已改 | A3 |
| **C2** | ~~端口/配置漂移~~ **已修复（2026-10-27）**：内核 `19433`、scheduler `28433` 两边默认一致；配置仍分三套（CLI settings.yaml / scheduler env / kernel env） | `Args.hs`、`cli.ts`、`index.ts` |
| **C3** | 事件列表两份（SSE 白名单 vs 事件注册表），漏改无测试会红 | `architecture/event-matrix.md:36` |

### 3.3 债务（D，已知）

| # | 问题 | 规模 |
|---|---|---|
| ~~**D1**~~ | ~~构建外 Haskell~~ **✅ 2026-10-27 已解决**：`sdk` 并入根构建；`haskell-network` 与 `go-haskell-bridge` 归档到 `archive/` | — |
| **D2** | `Presentation/` **未接入构建**（规划中的 Presentation 层，见 `presentation-layer.md`；`src/` 现仅存此层） | 8 文件 / 306 行 |
| **D3** | 36 个探针无聚合 exit code | 24 个探针二进制 |
| **D4** | Web 源码不在 CI（`dist` 已被 `/studio` 托管） | 17 文件 / 1.6k 行 |

---

## 4. 不是问题的取舍（改之前先读这一节）

| 取舍 | 为什么保留 |
|---|---|
| **三层两跳**（内核 / 编排 / 壳） | opencode 同样是 server + 多客户端；多出的一跳换来「内核可换成任意 OpenAI 兼容实现」 |
| **多语言**（Haskell + TS） | 类型论约束与本地推理需要 Haskell；编排生态需要 TS。**反例**：`/data/work/functional-programming/hs/haskell-agent` 用 30+ Haskell 包做到了完整 harness（含 runtime daemon、agent-server、TUI）——所以这是分工取舍，不是 Haskell 的限制（见 `reference/microkernel-lineage.md` §3.5） |
| **两套 wire**（内核三协议 + 编排 `/v1` 代理） | 内核面向任何客户端，编排面向前端与工具 |
| **工具只在 scheduler 执行** | 职责干净：内核只做协议转换，不做副作用 |
| **provider 注册表单一来源** | `/api/providers*` 全量转发内核，只存 `~/.trha/providers.json` —— 这是 S2 应当效仿的范式 |

---

## 5. 复核命令

```bash
# 分层与规模
find src -maxdepth 2 -type d | sort
for d in src/Core src/LLM src/API src/Infrastructure packages/scheduler/src \
         packages/app/CLI packages/app/Desktop/src packages/app/Web/src; do
  printf '%-28s %6s files %8s lines\n' "$d" \
    "$(find $d -type f \( -name '*.hs' -o -name '*.ts' -o -name '*.tsx' \) | wc -l)" \
    "$(find $d -type f \( -name '*.hs' -o -name '*.ts' -o -name '*.tsx' \) -exec cat {} + | wc -l)"
done

# S1 内核绑定与认证
rg -n "kernelBindAddress|kernelSettings|setHost" src/api/API/Server.hs
rg -n "loopback.host_rejected|content-type.not_json|Bearer" src/api/API/Security.hs
ls -l ~/.trha/kernel-token                           # 应为 -rw-------（64 hex）
ss -ltnp | grep 19433                                # 应为 127.0.0.1:19433

# S2 三处会话存储
rg -n "snapshot|\.json|writeFile" src/infra/Infrastructure/Storage/*.hs src/core/Core/Session/*.hs
sed -n 25,70p packages/scheduler/src/Server/stateStore.ts
rg -n "transcript.jsonl" packages/app/CLI/Core/Transcript.hs

# S3 内核 FSM
rg -n "AwaitingApproval|Planning|ExecutingStep" src --glob '*.hs'

# C1 插件引用
rg -ln "Core\.Plugin" --glob '*.hs' --glob '!dist-newstyle' .

# C2 端口
rg -n "haskellPort" packages/scheduler/src/Server/index.ts
rg -n "19433" packages/app/CLI/Core/Args.hs
```

---

## 6. 本文核实不了的

- **未跑端到端**（内核 → scheduler → 三壳）：结论来自静态代码与运行时监听面。
- **Desktop / Web 只读了目录结构**，未实机运行。
- **行号会漂移**：所有 `文件:行号` 是 2026-10-27 工作树位置，复核请用 §5 命令。
- **规模统计含测试文件**（CLI 的 118 文件 / 19.3k 行含 `test/`）。
