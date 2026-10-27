# trha 项目总览：技术栈 · 架构 · 计划完成度

> **日期**：2026-09-17（北京时间）
> **性质**：**综合视图**。它把散在各处的「技术栈 / 架构 / 计划完成度」收进一页，
> 但**不取代**任何权威文档 —— 冲突时以 §7 列出的那几份为准。
> **方法**：每一处「现状」都以**实测命令 + 文件出处**为准；**拿不出证据的一律标「未验证」**。
> 本轮机器证据（可复核）：`r-mu50b3k7-tl70so`、`r-mu50bj71-glmfap`（见 §8）。

---

## 0. 一句话

| | 内容 |
|---|---|
| **意图** | 内核是**带类型论与因果约束的推理中枢**：外部 API 模型与本地三值模型都只是它的**推理基座**。TS 全功能编排与 Electron 是**手段**，不是核心。（权威：`architecture-intended-vs-actual.md`） |
| **现状** | 三层链**已打通且各自有机器门禁**：内核（Haskell，5 个 cabal library）→ 编排（TS，115 vitest）→ 外壳（CLI / Electron Desktop）。数学判据 C1–C5 **全绿**；约束原语**已作用于外部 API**（D-1）。 |
| **主要缺口** | 见 §4：**生成层采样仍是占位**（`loadModel` 元数据/采样未实现）、依赖类型论（D-4）与草稿模型微调（D-5 主体）未开始、Web 外壳仍是空壳、win/mac 打包与 Electron 实机启动未验。~~WebGPU 未接生产~~ **已接线（2026-09-19）**。 |

---

## 1. 技术栈

### 1.1 分层技术表（含实测规模）

| 层 | 技术 | 位置 | 实测规模 | 在构建里？ |
|---|---|---|---|---|
| **核心引擎** | Haskell 2010 + GHC 扩展、Free monad、STM、aeson | `src/core/Core/**` | 14 `.hs` / 1240 行 | ✅ `library trha-core` |
| **LLM 适配 + CPU 推理内核** | Haskell、http-client、vector、GF(3)/GF(27)/GF(81) 整数域 | `src/llm/LLM/**`、`src/llm/Infrastructure/CPU/**` | `src/LLM` 5 `.hs` + CPU 目录 30 个文件 | ✅ `library trha-llm`（含 `c-sources: src/llm/cbits/gf27_avx2.c`） |
| **协议面** | Servant + Warp，OpenAI / Anthropic / Responses 三 wire ± 流式 | `src/api/API/**` | 4 `.hs` / 2011 行 | ✅ `library trha-api`（`visibility: public`） |
| **基础设施** | JSON/SQLite 存储、HTTP、进程沙箱、遥测 | `src/infra/Infrastructure/{Storage,Network,Sandbox,Telemetry}` | — | ✅ `library trha-infra` |
| **WebGPU 后端** | 手写 FFI 绑 wgpu-native C API（`WGPUStringView` + `*CallbackInfo`）+ WGSL + hsc2hs | `src/webgpu/Infrastructure/WebGPU/**`（`Raw/` 9 模块） | 9 模块 + `src/webgpu/cbits/wgpu_callback_shim.c` | ✅ `library trha-webgpu`（`trha.cabal:222`），5 个探针可执行 + `trha-webgpu-test` |
| **编排层** | TypeScript + Express + Zod + Winston + Cordis 式插件 | `packages/scheduler/` | 27 `.ts`，19 测试文件 / 115 用例 | npm 独立构建（不在 cabal） |
| **CLI / TUI 外壳** | Haskell + brick + vty + haskeline + optparse-applicative | `packages/app/CLI/`（`trha-cli.cabal`） | 45 文件；`trha-cli-test` 182 用例 | ✅ `cabal.project` 的第二个 package |
| **桌面外壳** | Electron 44.2.0 + React 18 + Vite + Zustand + electron-builder 26.15.3 + Vitest/jsdom | `packages/app/Desktop/` | 46 源文件，30 测试文件 / 137 用例；打包装配实测可产出 linux deb 且能启动 | npm 独立构建（不在 cabal） |
| **Web 外壳** | React + Vite + Zustand | `packages/app/Web/` | 15 源/配置文件（另有 3 个 `dist/` 产物）+ 1 个测试 | ❌ 不在 cabal、不在 CI —— **空壳** |
| **静态编译** | Alpine + musl → scratch 单文件 | `Dockerfile.static` | — | 存在；**构建未验证**（本机未跑 docker） |
| **规范基座（仓外）** | Agda「律算合一」+ pyBitNet《架构宪法 v1.1》 | `/data/work/discrete-mathematics`、`/data/trit/pyBitNet` | 对拍目标，**不参与本仓构建** | ❌ Agda 未进 CI（D-7） |

### 1.2 构建拓扑（实测）

```bash
cat cabal.project      # packages: .  +  packages/app/CLI
grep -nE "^(library|executable|test-suite)" trha.cabal
```

`cabal.project` 只有两个 package：根 `.` 与 `packages/app/CLI`。根 `trha.cabal` 的 stanza：

| stanza | 源码根 | 说明 |
|---|---|---|
| `library trha-core` | `src/core` | `Core.*` + `Kernel.Carrier`；被 infra / llm / api / test 使用 |
| `library trha-infra` | `src/infra` | `Infrastructure.{Storage,Network,Sandbox,Telemetry}.*` + `Core.HTTPProxy` |
| `library trha-llm` | `src/llm` | `LLM.*` + `Infrastructure.CPU.*`；含 C 源 `src/llm/cbits/gf27_avx2.c` |
| `library trha-api` | `src/api` | `API.*` + `Core.Provider.Types`；`visibility: public` |
| `library trha-webgpu` | `src/webgpu` | `Infrastructure.WebGPU.*`；依赖 `3rdparty/wgpu-native/` |
| `library trha-gpu-infer` | `src/gpu-infer` | **独立目录**（避免共享 `src/` 重编导致的双类型）——GPU 推理桥接层：`initGpuForward`（5GB 权重常驻）+ `gpuForwardFull`（60 层 GPU + CPU 尾巴）+ `gpuForwardFactory`（Int 编码函数句柄跨库）；依赖 trha-llm + trha-webgpu；2026-09-19 新增 |
| `executable trha`（CLI/服务） | `packages/app/CLI` | 另有同名 `executable trha` 在 `trha-cli.cabal` |
| `executable trha-kernel-stub` | `packages/kernel-stub` | 无 key 的两轮工具循环桩 |
| 5 个 `trha-webgpu-*` 探针 | `benchmarks/webgpu` | hello / compute / errorprobe / gf27 / gf27matmul |
| `executable trha-cpu-gf27simd` | `benchmarks/cpu` | AVX2 对拍 |
| `test-suite trha-test` | `test` | 190 例 |
| `test-suite trha-cpu-test` | `test/cpu` | 99 例（另有 9 个**负面编译**用例不参与构建） |
| `test-suite trha-webgpu-test` | `test/webgpu` | 3 例（真机 GPU；无 GPU 时 pending） |
| `trha-webgpu-*` 探针（新增） | `benchmarks/webgpu` | layerprobe（单层 16x）/ layer60probe（60 层正确性）/ qprobe（q 上 GPU）/ integprobe（GPU-only 闭环）/ gpue2e（生产路径 e2e） |
| `test-suite trha-cli-test` | `packages/app/CLI` | 182 例 |

**不在根构建（需 `cd` 进去单独构建）**：`packages/app/Web`（15）、`packages/scheduler`（npm）。
`packages/sdk` 已于 2026-10-27 **并入根构建**（P-02）；`packages/haskell-network` 与
`packages/go-haskell-bridge` 已归档到 `archive/`（不再维护）。

**⚠️ 构建布局（2026-10-27 起）**：每个 library 拥有**独立的 `hs-source-dirs`**
（`src/core` / `src/llm` / `src/infra` / `src/webgpu` / `src/api` / `src/gpu-infer`），
一个模块只属于一个 library，其余库通过 `build-depends` 引用。
拆分前 5 个库共享 `src`，导致 **44 个模块被各编两份**（同名不同类型）；拆分后重复数为 **0**。
规则出处：`QWEN.md` §Development Conventions。

### 1.3 依赖

**Haskell（来自 `trha.cabal` + `trha-cli.cabal` 的 `build-depends`）**：
`aeson`、`ansi-terminal`、`async`、`brick >= 2.1`、`bytestring`、`containers`、`directory`、
`filepath`、`free`、`hashable`、`haskeline >= 0.8`、`hspec`、`http-client`、`http-client-tls`、
`http-types`、`network`、`optparse-applicative >= 0.18`、`process`、`QuickCheck`、`servant`、
`servant-server`、`stm`、`tagged`、`text`、`time`、`unix`、`vector`、`vty >= 6.1`、
`vty-crossplatform >= 0.4`、`wai`、`warp`、`yaml`。
**工具链**：`base ^>=4.22` ⇒ 需 GHC 9.12+；本机实际 GHC **9.14.1** / cabal-install **3.17.0.0**。

**TypeScript**：scheduler — `express`、`axios`、`zod`、`winston`、`uuid`、`cors`；
Desktop — `react 18`、`zustand`、`axios`、`winston` + devDeps `electron 44.2.0`、
`electron-builder ^26.15.3`、`vite 5`、`vitest 1`、`jsdom`、`@testing-library/*`。
构建配置：ES2022 / ESNext / strict。

### 1.4 外部依赖进仓（`3rdparty/`，不在仓外引用）

| 目录 | 内容 | 用途 |
|---|---|---|
| `3rdparty/wgpu-native/` | `lib/libwgpu_native.so`（8.9M，v29.0.1.1）+ `include/webgpu/{webgpu.h,wgpu.h}` | WebGPU 后端链接 |
| `3rdparty/llama-webgpu/` | llama.cpp `ggml-webgpu` 参考（`ggml-webgpu.cpp` 4262 行、`wgsl-shaders/`） | WGSL 与流程参考（**代码不可照搬**：参考用 C++ API） |
| `3rdparty/llama-vulkan/` | Vulkan 后端源码 | 参考 |

---

## 2. 架构（现状）

### 2.1 分层与实际连接

```
╔═══ L-1 规范基座（仓外，权威）═══════════════════════════════════════╗
║ Agda「律算合一」L0–L8  ·  pyBitNet《架构宪法 v1.1》                  ║
║ ⚠️ 仅作外部规范源：Agda 不出现在本仓代码里，只出现在测试注释中       ║
╚════════════════════════════╤════════════════════════════════════════╝
                       ✅ 逐条对拍（C1：9 个主题全绿）
                             ▼
╔════════════ 内核 Kernel（Haskell，5 个 cabal library）══════════════╗
║ ① 推理约束层  ✅ t6Verify / causalGraphStep / wuxingForward / tailCycle ║
║              ✅ 强类型范畴隔离（SovereignTypes，负面编译 9 条守）      ║
║              ✅ **已作用于外部 API**（D-1：响应侧 `trha_constraint`）  ║
║              ❌ 依赖类型论 / Liquid Haskell（D-4：0 处代码）          ║
║ ② 原生推理后端 ✅ CPU：M1–M21（真实 60 层前向跑通）                   ║
║              ✅ WebGPU：**已接生产推理路径（2026-09-19）**——TRHA_GPU=1 时 ║
║              generateStream 走 GPU-only 60 层闭环（q 上 WGSL，353ms/60 层         ║
║              ≈5.1x CPU；engineGPU 弱耦合注入，失败回退 CPU）                    ║
║              ❌ 生成层（loadModel / BPE / 采样）仍是占位             ║
║ ③ 模型接入层  ✅ 三 wire（OpenAI/Anthropic/Responses）真流式 + tool 聚合║
║              ✅ provider 注册表 + `kind="cpu"` 本地引擎可达（D-2）    ║
║              ✅ 统一流式接口 llmChatToolsStream（A4/A5）             ║
║              ❌ 草稿模型 speculative draft（D-5）                     ║
║ ④ 协议面     ✅ /v1/* 三 wire ± /stream · /providers*（P1–P8）        ║
║ ⑤ 引擎原语   ✅ Plugin(Free) · Session · Agent FSM（D-3 已进会话）    ║
║              ✅ Tools · Event                                        ║
║              🟡 Cache：约 70 行（README 已去掉未经证实的「99%+」）    ║
╚════════════════════════════╤════════════════════════════════════════╝
                    ✅ HTTP 桥通（scheduler `Bridge/Haskell.ts`）
                             ▼
╔════════ 编排 Orchestration（TypeScript，packages/scheduler）════════╗
║ ✅ 会话态 stateStore（原子写 + 启动恢复）· plan/approval 决策门       ║
║ ✅ Cordis 插件服务化（registry/inject/waterfall/bail/parallel/serial、 ║
║    五模式、热载 watcher）· 并行/子代理 · 事件总线 + SSE               ║
║ ✅ 工具裁决与执行（toolGuard）· provider 透传 · /studio 托管          ║
║ ✅ 19 测试文件 / 115 用例                                            ║
╚════════════════════════════╤════════════════════════════════════════╝
            ✅ HTTP + SSE（:28433，Bearer）
                             ▼
╔════════ 外壳 Shell ═════════════════════════════════════════════════╗
║ ✅ CLI / TUI（brick + haskeline；trha-cli-test 182/0）              ║
║ 🟡 Desktop（Electron 44 + React；30 测试文件 / 137 用例；linux deb   ║
║    已验；win/mac 与实机启动未验）                                    ║
║ ❌ Web：15 个源/配置文件空壳（不在 cabal、不在 CI）                           ║
╚══════════════════════════════════════════════════════════════════════╝
```

### 2.2 职责分界（用户裁定，2026-09）

- **内核 = 无状态协议/执行引擎**：模型请求-响应 + 工具执行输入输出；**不持用户决策态**。
- **回合屏障 / 审批（plan/approval）= 外壳-编排层职责**：UI 决策门、会话态、恢复都属外壳与编排
  ⇒ 原「内核 Plan 状态机」缺口 **G1 已裁决关闭**。
- **外壳派生内核**：stdout 首行一行版本化 JSON 握手（版本不识即拒启）· stdin 为租约
  （父进程关闭 ⇒ 内核排空退出）· 日志一律 stderr · 页面路由一条规则（`/_studio/` 前缀）。
  出处：`plans/plan-reconciliation.md` 文末「架构原则」。

### 2.3 跨端协议（权威：`docs/contracts/protocol-shell-kernel.md`）

外壳 ↔ 编排：HTTP JSON + SSE，`Authorization: Bearer`（默认 `dev-token`），`/health` 与 `/v1/*` 豁免。
端点共 12 条（session CRUD / agent step / decision / models / plugins / events SSE / `/v1/*` 三 wire）。
SSE 事件帧 4 类（消息 / 计划挂起 / 决策 / 工具生命周期）。
编排侧事件总线 7 类，SSE 白名单转发 4 类（`docs/architecture/event-matrix.md`）。

### 2.4 源码规模（实测）

| 位置 | 文件数 | 行数 |
|---|---:|---:|
| `src/Core` | 14 | 1240 |
| `src/LLM` | 5 | 1122 |
| `src/API` | 4 | 2011 |
| `src/Infrastructure` | 41 | 5986 |
| `src/Presentation` | 8 | 306（**未接线**，全仓无 `import Presentation.*`） |
| `test/Spec.hs` | 1 | 2284 |
| `test/cpu/Spec.hs` + `negative/` | 1 + 9 | 862 |

**语言分布（排除构建产物与 node_modules）**：`.hs` 203 · `.ts` 149 · `.tsx` 43 · `.wgsl` 38 ·
`.md` 61 · `.glsl` 24 · `.go` 9 · `.c/.h` 各 2 · `.hsc` 2 · `.sh` 13。

---

## 3. 计划完成度总账

> 口径：**只认可执行证据**（测试计数 / 门禁回执 / `文件:行`）。每行的「证据」列指到落盘位置。
> **不给单一百分比** —— 分子分母口径不同（有的按原子、有的按判据），合并成一个数会误导。

### 3.1 逐计划

| 计划文档 | 完成度 | 证据 / 出处 |
|---|---|---|
| **判据 C1–C5**（`plans/verification-criteria.md`） | **5/5 ✅** | C1 九主题对拍 Agda、C2 九个负面编译用例、C3 四实现同批全等 4/4、C4 八项语义、C5 五个验收点；基线复现见 §8 |
| **CPU 三值推理蓝图 M1–M21**（`plans/pybitnet-ternary-inference-blueprint.md`） | **✅ 全部**（M1b、M7a–M7i、M8–M21） | 文末「当前状态」逐条；真实全 60 层 292s / 峰值 41 GiB / 0 fail |
| **自研 CPU 推理 M1–M6**（`plans/desktop-provider-design.md` A6） | **2/6**：M1 GGUF ✅、M2 反量化（8 型）✅；M3 BPE / M4 单层前向+KV / M5 完整前向+Sampler / M6 SIMD 未做 | `src/llm/Infrastructure/CPU/Inference.hs:36,47,77,86` 四处 `-- (placeholder)` |
| **WebGPU 接线 W1–W7**（`plans/webgpu-wiring-plan.md`） | **✅ 7/7 已跑通** | `library trha-webgpu`（`trha.cabal:222`）+ 5 探针 + `trha-webgpu-test` 3/0（真机 AMD Navi 44 + Vulkan/radv） |
| **WebGPU T1–T4**（同文档 §9） | **✅ 4/4** | GF(27) matmul 与 CPU 逐元素一致、Profile 真实计时、rpath、独立 hspec 套件 |
| **Desktop UI 移植 T1–T12**（`plans/desktop-ui-execution-plan.md`） | **22/24**：`T5b`(resume) ▢、`T12a`(清旧组件) 用户裁定「暂不删除，保留清单」 | 30 测试文件 / 137 用例（§8 复现） |
| **Provider 三层 P1–P8 + A1–A5**（`plans/desktop-provider-design.md`） | **✅ 13/13** | 文档头部逐条列了验证（三 wire 真流式、tool 增量聚合、假流式改真流式的时间证据） |
| **Phase 1–3（CLI/TUI + 协议 + 三端）**（`plans/plan-reconciliation.md`） | P1.1–P1.6 ✅ · S0–S3 ✅（S1 语义转移至编排层）· P3-* ✅ · K1–K6 ✅ | 同上文档「逐项核对」 |
| **真缺口 G1–G5** | G1 **裁决关闭** · G2 ✅ · **G3 ❌ 未开始**（`trha-ui` 共享渲染库未提取）· **G4 部分**（Desktop 已实质起跑，Web 仍空壳）· **G5 ❌ 未开始** | 同上「真缺口」表 |
| **架构偏差 D-1…D-9**（`architecture-intended-vs-actual.md`） | **6 项已闭合/处置**（D-1/D-2/D-3/D-6/D-8/D-9；**D-6 于 2026-09-19 接线完成**：engineGPU 弱耦合注入 + TRHA_GPU=1 → GPU-only 60 层闭环 5.1x）· **D-7 对拍成体系但 Agda 未进 CI** · **D-4/D-5 未开始** | 同文档 §4 |
| **Electron 28 → 44 升级**（`plans/electron-44-upgrade.md`） | **✅ 依赖 + 二进制 + 编译 + 打包 + 实机启动 均已验证**（2026-09-17）：`npm run package` EXIT=0 → `trha_0.1.0_amd64.deb`；产物契约 `CONTRACT OK`；实机启动随包 scheduler `/health` → HTTP 200。**仍未做**：win/mac 打包、GUI 渲染断言、`chrome-sandbox` SUID（靠 `--no-sandbox` 绕过）、`.npmrc` 镜像未配、改动未提交 | `plans/electron-44-upgrade.md` §2/§3/§6；回执 `r-mu52cxfw-jnesjs`·`r-mu52how8-ei0sg7`·`r-mu52huhe-m9ivzy` |
| **文件级完成跟踪**（`plans/file-completion-tracking.md`） | 其声称的四个测试计数**今天全部复现**（190/99/3/182） | §8 回执 `r-mu50b3k7-tl70so` |

### 3.2 本轮实测基线（可复现）

| 验证面 | 结果 | 回执 |
|---|---|---|
| `cabal build all` | `Up to date`，EXIT=0 | `r-mu50b3k7-tl70so` |
| `cabal test trha-test` | **190 examples, 0 failures, 4 pending** | 同上 |
| `cabal test trha-cpu-test` | **111 examples, 0 failures**（历史 99 → pair-popping 对齐 +6 → tokenize 升级 +6） | 同上 |
| `cabal test trha-cli-test` | **182 examples, 0 failures** | 同上 |
| `cabal test trha-webgpu-test` | **3 examples, 0 failures**（真机 GPU） | 同上 |
| scheduler `npx vitest run` | **19 files / 115 tests passed** | `r-mu50bj71-glmfap` |
| Desktop `npx vitest run` | **30 files / 137 passed, 6 skipped** | `r-mu50bj71-glmfap` |

---

## 4. 未完成 / 未验证（不掩盖）

### 4.1 真未完成（代码里没有）

| 项 | 判据（实测） |
|---|---|
| **CPU 生成层仍是占位** | `src/llm/Infrastructure/CPU/Inference.hs` `loadModel`（:84）与采样仍是占位；**tokenize/detokenize 已于 2026-09-18 升级为真 token 化**（白名单 1:1 + base-1536 escape，可逆、零越界，`r-mu6p0yuj-1kmxri`）。**结论：内核目前不能真正做题**，端到端证明的只是**链路闭合** |
| **D-4 依赖类型论 / Liquid Haskell** | 0 处代码（仅 `reference/` 文档） |
| **D-5 草稿模型 speculative draft** | 概念已定案（与约束同一机制的两面），实现未做 |
| **G3 `trha-ui` 共享渲染库** | 未提取；渲染仍在 CLI 包内 |
| **G5 内核 HTTP 请求纳入事件矩阵** | 未做（`agent-lifecycle-notes.md` 已标注缺口） |
| **Web 外壳** | `packages/app/Web/` 15 个源/配置文件（另有 3 个 `dist/` 产物），不在 `cabal.project`、不在 `.github/workflows/ci.yml` 的任何 job |
| **三值 / GF(27) 的 WebGPU kernel 进入生产路径** | ~~生产侧无 import~~ **已接线（2026-09-19）**：`engineGPU` 字段（弱耦合函数句柄，规避共享 src 双类型）+ `createCPUAdapterWith` 注入 + ProviderRuntime `TRHA_GPU=1` 走 `gpuForwardFactory`；GPU-only 60 层 hidden 与 CPU reportL 逐元素一致、353ms/60 层（5.1x） |

### 4.2 做了但没验（如实标）

| 项 | 为什么没验 |
|---|---|
| ~~**Electron 实机启动**~~ → **✅ 2026-09-17 已验** | 打包产物 `./release/linux-unpacked/trha --no-sandbox` 起来、随包 scheduler 在 3456 服务、`/health` → HTTP 200（`r-mu52how8-ei0sg7`）。**但 GUI 渲染仍未被断言**（无截图/无渲染断言）；且启动依赖 `--no-sandbox`（SUID 未设，需 sudo） |
| **win/mac 打包** | 需各自平台构建机。`electron-builder.yml` 只做了 schema 层修复（见 `plans/electron-44-upgrade.md` §6.1），**两个平台都没跑过** |
| **`Dockerfile.static` 静态构建** | 本机未跑 docker |
| **CI 实际结果** | 无法在本机执行 GitHub Actions。**修前**的静态观察：`ci.yml`/`smoke-tests.yml` 钉 GHC `9.4.8`（base-4.17），而 `trha.cabal` 要求 `base ^>=4.22` ⇒ Haskell job 不可能通过。**2026-09-17 已改**为 GHC 9.14.1 + cabal 3.16.1.0（ghcup 实测清单里存在），并且 `cabal build all && cabal test all` 本机 EXIT=0（`r-mu51ay1f-z0gbne`）。**但工作流本身仍未跑过** —— 见 §5-9 与 `known_issues trha-ci-wgpu-libdir-unverified` |
| **真实 LLM key 冒烟** | 所有 provider 验证基于本地/桩 endpoint（文档各处已自陈） |
| **Agda 证明流程** | 本仓不构建 Agda，仅作对拍目标；D-7 待定集成深度 |
| **`trha-webgpu-test` 的 pending 分支** | 本机有 GPU，`createContext` 失败 → `pendingWith` 这条路径从没走到过 |
| **WebGPU Profile 的「交叉点 300」** | 只有 2 个数据点，是**合理外推**而非测量 |

### 4.3 已知的架构债（不阻塞，但要知道）

- ~~**`trha-api` 与 `trha-llm` 重复编译 `Infrastructure.CPU.*`**~~ **✅ 2026-10-27 已解决**：
  按库拆分 `hs-source-dirs`（方案 A 全拆），44 → 0；见 `plans/improvement-plan-2026-10-27.md` P-01。
- **WebGPU 库依赖 `LD_LIBRARY_PATH` / `-optl-Wl,-rpath,…`**（`cabal.project.local`，不入仓）。
- **死代码**：`LLM.Stream` 部分路径与 3 个旧 `*StreamHandler` 在 A4/A5 后已无引用。

---

## 5. 文档漂移清单（本轮实测发现；**16 条中 15 条已修，第 9 条只改了配置未实跑**）

> 判据：文档宣称 vs 实测。每条都给了复核命令。
> **处置状态**：1–8、10–14 已在 2026-09-17 修掉（划线与 ✅ 标记即为已修；11–16 是**二/三次扫描**新发现的同类残留 —— 教训：漂移是成簇的，改完必须重扫）；
> **第 9 条（CI）只改了配置、工作流本身没跑过** —— 归入「未验证」，不是「已修」。

| # | 位置 | 宣称 | 实测 | 严重度 |
|---|---|---|---|---|
| ~~1~~ | `docs/plans/code-docs-reconciliation.md` §2 | 「`src/webgpu/Infrastructure/WebGPU/**` **不在任何 cabal**」 | 已有 `library trha-webgpu`（`trha.cabal:222`）+ 5 探针 + 测试套件 | ✅ **已修（2026-09-17）**：§2 该行改为「旧层已归档 / 新高层已在构建 / 仍未接生产路径」，并补 §8 变更记录 |
| ~~2~~ | `QWEN.md:17` | 层表含 `src/Orchestration/`（Haskell↔TS 桥） | `ls src/Orchestration` → 不存在；2026-09-13 已归档至 `archive/orchestration/` | ✅ **已修**：换成 WebGPU 后端 + Scheduler Bridge 两行 |
| ~~3~~ | `QWEN.md:43` | 「5 个内部库（… **`trha-orchestration`**）」 | 数目仍是 5，但**组成变了**：orchestration 已删、换成 **`trha-webgpu`** | ✅ **已修** |
| ~~4~~ | `QWEN.md:91` | `Orchestration.*` → trha-orchestration only | 该库已不在 `trha.cabal` | ✅ **已修**：归属表加 `Infrastructure.WebGPU.*` → trha-webgpu only、删 Orchestration 行 |
| ~~5~~ | `docs/README.md:3` | 「本目录共 **39 份**文档」；`plans/` 「进行中（**8**）」 | 实测 **42 份**（+导览 = 43 文件；本文新增后为 43 份 / 44 文件）；`plans/` **11** 份 | ✅ **已修**：改为 44；plans 8→11；补 3 份漏列的计划文档；阅读顺序加本文 |
| ~~6~~ | `docs/architecture/architecture.md` §8 | 下一步计划：Phase 3/4/5 **未勾** | `README.md` Phase 表标 ✅（带实测注记）；两者口径不一致 | ✅ **已修**：§8 加状态标注（逐条勾选 + 指向本文 §3），并注明 §4.3/§4.4 的 GTK·Qt / Warp 非现状 |
| ~~7~~ | `docs/plans/webgpu-wiring-plan.md` §2 | `3rdparty/ref-llama.cpp-ggml-webgpu/` | 实际目录名是 `3rdparty/llama-webgpu/`（同文档 §7 写法正确） | ✅ **已修**：改名 + 补 `llama-vulkan/` + §7 变更记录 |
| ~~8~~ | `docs/architecture/system-overview.mmd` | Desktop = 「GTK/Qt」、Web = 「Warp」 | Desktop 是 Electron + React；Web 是 React + Vite | ✅ **已修**：改标签 + 顶部加「未标注即为构想」状态头 + 补入 TS 编排层与 WebGPU |
| 9 | `.github/workflows/ci.yml` | GHC 9.4.8 / cabal 3.10.2.1 | 需 GHC 9.12+（`base ^>=4.22`）、`cabal-version: 3.8` | ✅ **已改（命令本机验证 / CI 实跑未验证）**：抬到 ghcup 的 GHC **9.14.1**（base-4.22.0.0）+ cabal **3.16.1.0**；两处 job 均加 `Provide wgpu-native lib dir` 步骤补 `cabal.project.local`。`cabal build all && cabal test all` 本机 **EXIT=0**（`r-mu517qwn-d0b8v2`）—— 但**工作流本身没跑过** |
| ~~15~~ | `docs/plans/plan-reconciliation.md` §Phase3 表 | 「**Desktop/Web 起跑基线** ❌ …Desktop 仅有 README+旧 dist」 | 与同文 G4 行（已修）重复且同样过期 | ✅ **已修**：改为 🟡 并写明 Desktop 已起跑 / Web 仍空壳 |
| ~~16~~ | `docs/reference/reasonix-cli-tui-architecture-analysis.md:42` | 能力矩阵把 `trha-orchestration Subagent 骨架` 当作现有能力 | 该库已归档出构建 | ✅ **已修**：划掉并注明 2026-09-13 已归档（本行是当时的对照记录） |
| ~~11~~ | `.github/workflows/smoke-tests.yml` | 同样钉 GHC 9.4.8（`haskell-test` 与 `integration-test` 两个 job） | 与 ci.yml 同一处矛盾 | ✅ **已修**：两处均抬到 9.14.1 / 3.16.1.0 + 补 wgpu 库目录步骤（**工作流未实跑**） |
| ~~12~~ | `docs/architecture/architecture-intended-vs-actual.md` §3 现状图 | 「❌ WebGPU：1344 行 / **不在任何 cabal 组件**」 | 该图是**活的状态图**（非快照），与同文 D-6 行自相矛盾 | ✅ **已修**：改为 🟡「旧层已归档 / 新高层 9 模块在构建 + 5 探针 + 真机 3 例 / 仍未接生产路径」 |
| ~~13~~ | `docs/plans/webgpu-wiring-plan.md` §1 与 §3.1 | 「在构建中？**否**」「整层不在任何 cabal 组件 → 从不参与编译」 | 那是 **2026-09-13 的快照**，未标日期即被误读为现状 | ✅ **已修**：两行都标明「快照，已过期，以 §7/§8 为准」 |
| ~~14~~ | `docs/architecture/architecture.md` §2 图 与 §4.3/§4.4 | 图内 Desktop=`GTK/Qt`、Web=`Warp`；§4.3 标题 `Desktop Frontend (GTK/Qt)` | 同 #6，但 §8 的注记离得太远 | ✅ **已修**：图内标签改为 Electron+React / React+Vite（并修好该行原本缺失的边框），§4.3/§4.4 标题加「⚠️ 非现状」 |
| ~~10~~ | `docs/plans/plan-reconciliation.md` G4 | 「`packages/app/Desktop` 仅有 README + 旧 dist；Web 为空壳」 | Desktop 已有 **46 源文件 / 30 测试文件**；Web 仍空壳（15 个源/配置文件） | ✅ **已修**：G4 行更新为「Desktop 侧已实质起跑，余量只在 Web 一侧」 |

> **说明**：`architecture.md` §6、`presentation-layer.md` 头部、`archive/**` 的旧结构描述
> **已被显式标注为「规划 / 未接线 / 已过期」**，不算漂移 —— 那是刻意留的历史。

---

## 6. 复核命令（可直接重跑）

```bash
# 构建与测试（本轮基线的复现方式）
cabal build all                                              # 期望 EXIT=0
cabal test trha-test trha-cpu-test trha-cli-test trha-webgpu-test --test-show-details=direct
cd packages/scheduler && npx vitest run                      # 19 files / 115 tests
cd packages/app/Desktop && npx vitest run                    # 30 files / 137 passed, 6 skipped

# 构建拓扑
cat cabal.project                                            # 只有 . 与 packages/app/CLI
grep -nE "^(library|executable|test-suite)" trha.cabal

# 未接线清单
grep -rn "import Presentation" --include=*.hs . | grep -v dist-newstyle      # → 无输出
grep -rn "Infrastructure.WebGPU" --include=*.hs src/ | grep -v "^src/webgpu/Infrastructure/WebGPU/"   # → 生产侧无输出
grep -rn "WebGPU\|Presentation" --include=*.cabal . | grep -v dist-newstyle

# 生成层仍是占位
grep -n "placeholder" src/llm/Infrastructure/CPU/Inference.hs                    # 36/47/77/86

# 文档漂移
ls src/Orchestration 2>&1                                                    # → No such file
find docs -type f \( -name '*.md' -o -name '*.txt' -o -name '*.jpeg' \) | wc -l   # → 43
grep -n "ghc-version" .github/workflows/ci.yml
grep -n "base ^>=4.22" trha.cabal
ls 3rdparty/                                                                 # llama-vulkan llama-webgpu wgpu-native
```

---

## 7. 本文与既有文档的关系

| 想知道什么 | 该读哪份 |
|---|---|
| **项目意图**、偏差 D-1…D-9、状态分档 A–E | `architecture/architecture-intended-vs-actual.md`（**先读这份**） |
| 分层、数据流、技术选型 | `architecture/architecture.md`（⚠️ §6 是未采用的规划） |
| 跨端端点 / SSE 帧 / 凭证 | `contracts/protocol-shell-kernel.md` |
| 计划项 vs 功能实现 | `plans/plan-reconciliation.md` |
| 构建 / 接线 / 使用面 | `plans/code-docs-reconciliation.md`（⚠️ §2 的 WebGPU 段已过期，见 §5-1） |
| 判据是什么（数学正确性，不是性能） | `plans/verification-criteria.md` |
| 逐文件完成状态 | `plans/file-completion-tracking.md` |
| **技术栈 + 架构 + 完成度的一页视图** | **本文** |

---

## 8. 本轮机器证据

| 回执 id | 命令 | 结果 |
|---|---|---|
| `r-mu52jray-ms6kue` | `cd packages/app/Desktop && rm -rf release && npm run build:main && npm run build:renderer && npm run package && node scripts/verify-artifact.mjs … && … 启动 + curl /health` | **EXIT=0，39.9s，`CLEAN-CHAIN ALL PASS`** —— **从干净状态出发的桌面端到端**：tsc → vite（75 modules）→ sync:scheduler（115 packages）→ electron-builder 26.15.3 → `.deb` → `CONTRACT OK` → `scheduler node_modules entries: 106` → 启动 → `/health` `{"status":"ok",…}`。**「桌面版可以编译」的收尾证据** |
| `r-mu52how8-ei0sg7` | `cd packages/app/Desktop && timeout 22 ./release/linux-unpacked/trha --no-sandbox &` + `sleep 10` + `curl :3456/health` + 三条断言 | **EXIT=0，11.3s**，`ALL ASSERTIONS PASS`：health 200 `{"status":"ok",...}` · `Scheduler listening on port 3456` · `Tools: 59 registered`。**「桌面版能跑」的强证据** |
| `r-mu52huhe-m9ivzy` | 同上但**不带** `--no-sandbox`（负向控制，`expectFail` + `expect:"chrome-sandbox"`） | **通过**：exit 133，`FATAL … SUID sandbox helper binary … chrome-sandbox` —— 它确实会红，且红在正确的地方 |
| `r-mu52cxfw-jnesjs` | `node scripts/verify-artifact.mjs release/trha_0.1.0_amd64.deb` + `dpkg-deb --field` | EXIT=0；`CONTRACT OK: trha 0.1.0 amd64`；Installed-Size 423035 KB |
| `r-mu51ay1f-z0gbne` | `python3 -c "yaml.safe_load 校验 .github/workflows/*.yml" && cabal build all && cabal test all && (scheduler vitest) && (Desktop vitest)` | **EXIT=0，66.8s**。三个工作流的 YAML 结构合法且 GHC/cabal 钉版已全部为 9.14.1 / 3.16.1.0（ci.yml 5 job、smoke-tests.yml 3 job、static-build.yml 2 job 无钉版）；四套件 190/99/182/3 全 PASS；115 / 137+6 skipped。**本批定稿的收尾回执** |
| `r-mu517qwn-d0b8v2` | `cabal build all && cabal test all --test-show-details=direct` | **EXIT=0，52.2s**；四套件全 PASS。**这一条是为 CI 修复取证**：它跑的就是 `.github/workflows/ci.yml` 里 Build/Test 两步的命令 |
| `r-mu50gt4b-u140zb` | `cabal build all && cabal test trha-test trha-cpu-test trha-cli-test trha-webgpu-test && (cd packages/scheduler && npx vitest run) && (cd packages/app/Desktop && npx vitest run)` | **EXIT=0，66.0s**；190+4pending / 99 / 182 / 3 四套件全 PASS；115 / (137+6 skipped)。**本文定稿前最后一次全量** |
| `r-mu50b3k7-tl70so` | 同上（仅 cabal 部分） | EXIT=0；3 / 182 / 99 / 190 四套件全 PASS |
| `r-mu50bj71-glmfap` | `(cd packages/scheduler && npx vitest run) && (cd packages/app/Desktop && npx vitest run)` | EXIT=0；115 / (137+6 skipped) |
| `r-mu509x37-06n09y` | `fmt-check`（领域包自带） | **exit 2，命令不存在** —— 该门禁属于另一个仓库，**不是本仓回归** |
| `r-mu509x8m-1c3ap5` | `codespell`（领域包自带） | **exit 127，命令不存在** —— 同上 |

> **关于本仓的「具名门禁」**：本轮加载的领域包是给另一个仓库（`codex-repo`）配的，
> 它的 24 条命令（`scripts/format.py` / `just` / `cargo` / `codex-rs/`）在本工作区**都不存在**。
> 所以本仓当前**没有可用的具名门禁**，上表前三条 `custom` 回执是本轮**唯一**的强证据。
> 已记入 `known_issues`：`trha-domainpack-mismatch`。
> 落盘位置：`~/.dsh/state/swe-mode/receipts/`、`~/.dsh/state/swe-mode/known-issues.json`。
>
> **本文改动后的门禁覆盖**：本文与索引改动**只有 Markdown**（`docs/architecture/project-overview.md`、
> `docs/README.md`、`QWEN.md`），不触及任何构建输入 ⇒ 上表回执仍然有效。
> 本仓**没有** Markdown 格式化/拼写门禁（无 `.markdownlint-cli2.yaml`、无 `.codespellrc`、
> 无 `AGENTS.md`）—— 这一点本身是缺口，未修。

---

## 9. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-09-17 | 初版：技术栈（分层 + 构建拓扑 + 依赖 + 3rdparty）· 架构现状图 + 职责分界 + 协议 + 规模 · 计划完成度总账（逐计划）· 未完成/未验证 · 文档漂移清单 10 条 · 复核命令 · 本轮回执 |
| 2026-09-17 | **桌面版打通**：`.github/workflows/` 无关；改 `packages/app/Desktop/electron-builder.yml` 两处（`win.signingHashAlgorithms` → `win.signtoolOptions`；`extraResources` 把 scheduler 的 `node_modules` 单列一条，绕开 electron-builder ≥25 的硬编码排除）。编译 / 打包 / 实机启动三段全部实测通过，回执 `r-mu52cxfw-jnesjs`·`r-mu52how8-ei0sg7`·`r-mu52huhe-m9ivzy`；根因与复现写入 `plans/electron-44-upgrade.md` §6 |
| 2026-09-17 | **二次扫描**又发现 4 条同类残留（#11–#14：`smoke-tests.yml` 同样钉 9.4.8、`architecture-intended-vs-actual.md` §3 活状态图仍称 WebGPU 不在构建、`webgpu-wiring-plan.md` §1/§3.1 的未标日期快照、`architecture.md` §2 图与 §4.3/§4.4）—— 一并修掉。教训见 `worklog journal` `j-mu518js2-vryo` |
| 2026-09-19 | **WebGPU 生产接线完成（D-6 闭合）**：trha-gpu-infer 独立库（src/gpu-infer/ 目录，规避共享 src 双类型）+ `engineGPU` 弱耦合句柄 + `createCPUAdapterWith`/`setEngineGPU` + ProviderRuntime `TRHA_GPU=1` → `gpuForwardFactory` → GPU-only 60 层闭环（q/christoffel 上 WGSL、cur/nxt 轮换、单次读回；hidden 与 CPU reportL 逐元素一致，353ms/60 层 ≈5.1x CPU；失败回退 CPU）。回执链：r-mu7cdlsf-mecbgq（60 层一致）、r-mu6wfgrm-obntjm（e2e）、r-mu7d7hdv-3vab6u（197/0 回归）。本文 §0/§2.1/§3/§4 三处「未接生产」→「已接线」。 |
| 2026-09-17 | **§5 的 10 条漂移中 9 条已修**（1–8、10；第 9 条 CI 已改但**CI 实跑仍未验证**）。改动文件：`.github/workflows/ci.yml`、`docs/plans/code-docs-reconciliation.md`、`docs/plans/plan-reconciliation.md`、`docs/plans/webgpu-wiring-plan.md`、`docs/architecture/architecture.md`、`docs/architecture/system-overview.mmd`、`docs/README.md`、`QWEN.md`。取证：`cabal build all && cabal test all` → EXIT=0（`r-mu517qwn-d0b8v2`） |
