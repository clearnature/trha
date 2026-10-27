# trha 改进计划（2026-10-27）

> **输入**：
> 1. qwen 的独立评价（2026-09-20，`/home/yanli/.qwen/projects/-home-yanli/chats/4c4ffc86-…jsonl` 第 1917 条，S1–S6）；
> 2. 本仓的对照评审（`reference/trha-architecture-benchmark-review.md`，A1–A8）；
> 3. 2026-10-27 的**现状复核**（本文重新跑命令核实，不照抄旧结论）。
>
> **判据**：安全 > 正确性 > 可维护性 > 性能。与项目 C1–C5 不冲突。

---

## 0. 现状复核：qwen 的六个问题，哪些还在

| qwen 编号 | 2026-09-20 结论 | 2026-10-27 复核 | 状态 |
|---|---|---|---|
| **S1** | 41 个模块被两个 library 各编译一份 | **2026-10-27 已修复**：按库拆分 `hs-source-dirs`（方案 A 全拆），脚本重跑 **44 → 0**；`cabal build all` EXIT=0 | ✅ 已解决 |
| **S2** | ~~~13.6k 行 Haskell 在构建外（43%）~~ | **2026-10-27 已处置**：`packages/sdk`（15 文件 / 1,059 行）**并入根构建**；`packages/haskell-network`（17 文件 / 1,143 行）与 `go-haskell-bridge` **归档**到 `archive/`。旧值 92 文件 / 11,781 行是误把 `dist-newstyle` 计入 | ✅ 已解决 |
| **S3** | `src/Presentation/**` 306 行 | 8 个 `.hs`，`trha.cabal` 仍 0 引用；**但它是规划中的 Presentation 层**（`architecture/presentation-layer.md`），应读作「未接线」而非「死代码」 | 🟡 未接线（规划中） |
| **S4** | 36 executable + 3 test-suite，探针无聚合 | `grep -c '^executable'` = **26**（有减少），仍无聚合 runner | 🟡 部分缓解 |
| **S5** | 「性能不是判据」被用到"大脑"（222s/token） | 未复核（需 `.sov` 模型 + 长时间） | ❓ 未验证 |
| **S6** | 文档产出快于实现（缓存 99%+、WebGPU ✅） | 缓存与 WebGPU 的描述已修正；但仍发现两处漂移：`protocol-shell-kernel.md:174`（"外壳未接入流式"）、`architecture.md:127`（"/v1 不推进 FSM"） | 🟡 部分缓解 |

**本轮已解决**（qwen 没提、我们后来发现并修掉的）：

| 问题 | 修复 |
|---|---|
| 内核绑 `0.0.0.0` 且无认证 | `127.0.0.1` + loopback gate（Bearer / Host / Origin / JSON）+ per-launch token |
| 端口漂移（8080 vs 3333） | 统一为内核 `19433` / scheduler `28433` |
| 没有停止命令、pid 不可追踪 | `trha stop/status` + `~/.trha/run/*.pid`（校验 cmdline，SIGTERM） |
| quit/stop 语义混乱 | quit 只退壳；stop 三端共用一套实现 |

---

## 0.1 术语：未接线 ≠ 死代码

项目仍在开发中，以下三类必须分开，不能一律按「死代码」处理：

| 类别 | 定义 | 本仓例子 | 处理 |
|---|---|---|---|
| **未接线（规划中）** | 有设计文档 / 规划位置，尚未被构建或调用方使用 | `src/presentation/**`（`architecture/presentation-layer.md`） | **保留**，按规划推进（`Core.Plugin`、`sdk`、`haskell-network` 已分别归档/并入） |
| **废弃** | 曾被使用、已被替代，规划中不再有位置 | 已归档的 `archive/orchestration/` | 归档（保留历史） |
| **无位置** | 既无规划出处、也无调用方 | ~~`packages/go-haskell-bridge`~~ | **已于 2026-10-27 归档**（用户裁定：不需要 Reasonix 的 Go 桥） |

判据不是「有没有被 import」，而是「**规划里有没有它的位置**」。

---

## 1. 架构图（现状）

```
L3 壳   TUI / CLI (Haskell)   Desktop (Electron)   Web (React, /studio)
              │                      │                    │
              └──────── HTTPS + Bearer ────────────────────┘
                                ▼
L2 编排  packages/scheduler (:28433, Express)
         runStep: bail → tools waterfall → contextGovernor → Bridge → 工具执行 → 下一轮
         ├─ 会话/事件：/api/session/*  /api/events/:id (SSE)
         ├─ 工具：standard/extra/browser/lsp/mcp/skills
         └─ 插件：ctx.service/on/waterfall/bail（Cordis 式，进程内）
                                │ HTTP + Bearer(kernel-token)
                                ▼
L1 内核  src/api/API/Server.hs (:19433, Warp)
         ├─ 主路径  /v1/{chat/completions,messages,responses}(±stream)
         │            → resolveAdapterIO → provider（openai/anthropic/responses/cpu）
         │            → touchKernelSession（镜像 projections + FSM）
         ├─ 旁路径  /agent/step（FSM 会话原语，**用 default adapter = stub**）
         ├─ 会话    eventLog / projections / agentState / plan + checkpoint
         └─ 约束    verdictOf / verdictOfWithState（T⁶ + 因果图）
                                │
L0 规范  Agda（律算合一）+ pyBitNet 宪法 —— 外部对拍源，不参与构建
```

**两条 API 路径的能力差异**（2026-10-27 实测）：

- `/v1/*`：真实云端模型（`deepseek-flash` 返回「你好」，usage 45 tokens）+ 约束判定；
- `/agent/step`：`[stub] hello`（default adapter），但同样推进 FSM、写 projections。

---

## 2. 问题清单（qwen + A1–A8 合并去重）

| # | 问题 | 来源 | 严重度 | 证据 |
|---|---|---|---|---|
| ~~**P-01**~~ | ~~44 个模块被两个 library 各编译一份~~ **✅ 已完成（2026-10-27，方案 A 全拆）**：`src-{core,llm,infra,webgpu,api}/` 各自拥有模块；`trha-api` 的 44 项 `other-modules` 删除 | qwen S1 | — | 解析脚本：72 条目，**0 重复**；`cabal build all` EXIT=0 |
| ~~**P-02**~~ | ~~构建外代码~~ **✅ 已完成（2026-10-27）**：sdk 拆分（`src/core`/`src-client`/`src-utils`）后并入根 `cabal.project`；重复的 `Core.Server/Handlers`、`Types.Config`、`Server.Main` 归档到 `archive/sdk-legacy/`；`haskell-network` 整体归档 | qwen S2 | — | `cabal build all` 含 `trha-sdk-*`；`trha-sdk-test` 9/0 |
| ~~**P-03**~~ | ~~`/agent/step` 不解析 provider~~ **✅ 已完成（2026-10-27）**：`StepReq` 增加可选 `provider`，`agentStepHandler` 走 `resolveAdapterIO`（与 `/v1/*` 同一条解析） | 本轮 | — | `cabal build trha-test` EXIT=0 |
| **P-04** | **会话真相三份**（内核 checkpoint / scheduler stateStore / CLI transcript），无权威 | A1 | 🟠 | `Core/Session/Types.hs`、`stateStore.ts`、`Core/Transcript.hs` |
| ~~**P-05**~~ | ~~插件层名实不符~~ **✅ 已归档（2026-10-27）**：`archive/haskell-plugin/Core/Plugin/*` + `test/PluginSpec.hs` → `archive/haskell-plugin/` | A3 + qwen 技术栈评价 | — | 全仓 `Core.Plugin` 引用为 0 |
| **P-06** | **内核 FSM 与 2026-09 裁定冲突**（裁定"内核无状态"，实现持 FSM/审批/持久化） | A4 | 🟠 | `Manager.hs` vs `plan-reconciliation.md` |
| **P-07** | **Presentation 层未接线**（规划中，306 行） | qwen S3（措辞需修正） | 🟡 | 8 文件，0 引用；设计见 `architecture/presentation-layer.md` |
| ~~**P-08**~~ | ~~探针无聚合 runner~~ **✅ 已完成（2026-10-27）**：`scripts/run-probes.sh` 聚合 PASS/FAIL/SKIP 与 exit code | qwen S4 | — | 脚本已跑（见回执） |
| **P-09** | **配置三套**（CLI settings.yaml / scheduler env / kernel env） | A5 剩余 | 🟡 | — |
| **P-10** | **Web 壳定位不明**（1.6k 行不在 CI，但 `dist` 被 `/studio` 托管） | A7 | 🟡 | — |
| ~~**P-11**~~ | ~~事件双列表~~ **✅ 已完成（2026-10-27）**：`Core/EventRegistry.ts` 单一来源；SSE 路由循环订阅/退订 | A8 | — | `tsc --noEmit` + `event-registry.test.ts` 2/2 |
| **P-12** | **"大脑"无性能门禁**（222s/token） | qwen S5 | 🟡 | 未复核 |
| ~~**P-13**~~ | ~~两处文档漂移~~ **✅ 已完成（2026-10-27）**：`protocol-shell-kernel.md:188`（外壳已接入 SSE）+ `architecture.md:139`（带 sessionId 时推进 FSM） | 本轮 | — | 文档已改 |
| ~~**P-14**~~ | ~~Go 桥 906+499 行无人引用，且无规划出处~~ **✅ 已归档（2026-10-27）**：`packages/go-haskell-bridge` → `archive/go-haskell-bridge/` | qwen | — | `git mv` 完成；全仓引用检查为 0 |

---

## 3. 改进路线

### P0 —— 正确性与安全（1–2 天）

| 项 | 做什么 | 验收 |
|---|---|---|
| ~~**P-03**~~ | ~~`agentStepHandler` 走 `resolveAdapterIO`~~ **✅ 已完成** | 已按请求级 provider 解析 |
| ~~**P-13**~~ | ~~修两处文档漂移~~ **✅ 已完成** | 文档与代码一致 |
| **P-04（第一步）** | 写一篇"会话真相"契约：声明唯一权威 + 其余为投影 | `contracts` 新增一节；两条一致性测试（三处恢复后消息序列相等） |

### P1 —— 门禁与结构（1–2 周）

| 项 | 做什么 | 代价 |
|---|---|---|
| ~~**P-02**~~ | ~~保持独立构建并加独立 CI job~~ **✅ 已改为并入主线**（用户裁定「进行拆分，合并归档，并入主线」） | 已完成 |
| ~~**P-01**~~ | ~~拆分方案~~ **✅ 已完成**：方案 A（按库拆 `src-*/`），44→0；`QWEN.md` 的 ownership 表已重写 | 已完成 |
| ~~**P-08**~~ | ~~加 `scripts/run-probes`~~ **✅ 已完成**：`scripts/run-probes.sh` | 已完成 |
| **P-09** | 端口/配置单一来源（port 文件或显式传递） | 中 |
| ~~**P-11**~~ | ~~SSE 白名单从注册表派生~~ **✅ 已完成**：`Core/EventRegistry.ts` | 已完成 |

### P2 —— 清理与定位（按计划）

| 项 | 做什么 | 备注 |
|---|---|---|
| **P-07** | **保留**（规划中）；若长期不接，再决定归档 | 它是 Presentation 层的设计落点，不是死代码 |
| ~~**P-05**~~ | ~~`Core.Plugin` 接线或归档~~ **✅ 已归档** | 已完成 |
| **P-06** | 统一审批 FSM 的归属（承认内核持有 / 迁移到编排） | 先改文档再动代码 |
| **P-10** | Web 定位（静态 studio / 独立客户端） | 产品决策 |
| **P-12** | 给"大脑"设宽松性能门禁 | 需 `.sov` 模型 |

---

## 4. 需要用户裁定的两项

1. ~~**P-01（44 个重复模块）**~~ **已裁定并执行（2026-10-27）**：类型唯一性属于第一判据，采用方案 A 全拆。
   - 结果：44 → 0；`trha-api` 不再重编其他库；`mkCPUApp` 的"两个 LLMAdapter"绕行代码可后续清理。
2. **P-07（Presentation 层的接线节奏）**
   - `Presentation/` 有规划位置，问题不是"删不删"，而是"什么时候接、接到哪个壳"。
   - ~~P-14 Go 桥~~ **已归档（2026-10-27）**，不再需要裁定。

---

## 5. 不建议做（qwen 与本文一致）

- 不要为了"像主流 agent 框架"补 MCP/工具生态——差异化在约束层，编排已由 TS 补齐。
- 不要现在换掉 Electron——外壳不是核心，换它是纯成本。
- ~~不要为了"消除重复编译时间"去拆 `hs-source-dirs`~~ **2026-10-27 已按「类型唯一性」执行拆分**：理由是第一判据，不是构建速度。
- **不要把"规划中但未接线"的代码判为死代码**：`src/presentation/` 有设计位置，不是垃圾（`Core.Plugin`、`sdk`、`haskell-network` 已按 2026-10-27 裁定处置）。

---

## 6. 核实命令

```bash
# P-01 重复模块
python3 - <<'PY'   # 见 docs/reference/trha-architecture-review.md §2
PY

# P-02 构建外代码
cat cabal.project
find packages/sdk -name '*.hs' | wc -l
find packages/sdk -name '*.hs' -exec cat {} + | wc -l

# P-03 两条路径
curl -s -H "Authorization: Bearer $(cat ~/.trha/kernel-token)" \
     -H 'Content-Type: application/json' \
     -d '{"sessionId":"probe","message":"hi"}' \
     http://127.0.0.1:19433/agent/step | head -c 200
curl -s -H "Authorization: Bearer $(cat ~/.trha/kernel-token)" \
     -H 'Content-Type: application/json' \
     -d '{"model":"deepseek-flash","messages":[{"role":"user","content":"你好"}]}' \
     http://127.0.0.1:19433/v1/chat/completions | head -c 200

# P-07 / P-14：未接线与无出处
grep -c Presentation trha.cabal
grep -rn "go-haskell-bridge" cabal.project trha.cabal src scripts | wc -l
```
