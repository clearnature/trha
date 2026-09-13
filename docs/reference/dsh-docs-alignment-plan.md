# deepseek-harness docs 概念对齐计划（Fable 5）

> 2026-09（北京时间）。范围：`/home/yanli/work/deepseek-harness/docs` 十份核心概念文档，
> 对照 trha（Haskell 内核 + TS 编排 `packages/scheduler` + CLI/TUI），规划实现与原子任务分解。
> 状态：**✅ 全部落地**（T1–T11 完成，证据链：Haskell 182/182 · TS 89/89 · 各原子 E2E）。

## Step 1 · 拓扑扫描：概念 ↔ trha 核对矩阵

| 文档 | 核心概念 | trha 状态 | 证据 / 缺口 |
|---|---|---|---|
| `architecture` | 能力缝 = `ctx.<key>` 服务 + 事件面；「加 X=注册到 Y」机制表 | ✅ 已落地 | registry + 机制表 `dsh-capability-seams.md` + `ctx.sessions`（T8/T9）|
| `agent-lifecycle` | turn/step 生命周期与事件 | ✅ 已落地 | `runStep` + 生命周期比对文档（T11）|
| `event-producer-consumer` | 事件生产/消费矩阵 | ✅ 已落地 | `event-matrix.md`（producer/consumer/SSE/持久化）（T4）|
| `tool-execution-pipeline` | 工具执行管线（注册→schema→guarded 执行）| ✅ 已落地 | `ctx.tools` 服务化 + guarded 执行（T5/T7）|
| `tool-catalog` | 工具 schema 目录（逐工具契约）| ✅ 已落地 | `toolCatalog.ts` 单一来源 + 测试（T6）|
| `persistence-catalog` | 会话事件 **envelope**（id/ts/type/payload）+ 事件目录 | ✅ 已落地 | `v/id` 信封 + `EventKind` 注册表 + `model-request`（T1/T2/T3）|
| `capability-seams` | seam/能力服务 + 投影 | 🟡 部分 | 服务能力面（capabilities）已有；seam 文档缺失 |
| `defensive-patterns` | 路径/不可信输出/异步状态 防御 | 🟢 部分 | workspace 路径校验 ✓；**symlink 逃逸未防**（realpath）、输出大小无上限 |
| `cordis-api` | registry/inject/事件五模式/逆转 | 🟢 已落地 | 全五模式+watcher+releases（79 TS 测试 + E2E）|
| `config-catalog` | 插件/设置契约目录 | 🟢 已对齐 CLI 端 | 15 键 schema/面板/校验；缺 **machine-readable 键表导出** |

## Step 2 · 多路径推演（两处主要决策）

**D1 — seam 模型落地方式**
- 路径 A（推荐，增量）：保持单编排包，把「内置服务/工具/sessionState」整理为**能力缝表文档** + 将 `AGENT_TOOLS` 提为 `tools` 服务（list/execute）；复杂度低、可测、不重排架构。
- 路径 B：按 deepseek `core/session|tools|scope…` 拆子包（成本高、与单包现状冲突大）。
- 决策：A；备选 B 留档。

**D2 — 事件信封迁移**
- 路径 A（推荐）：新事件写 `{v:1, id, ts, type, payload}`；读兼容旧行（无 envelope 的旧 transcript 仍可回放）；类型注册表 `EventTypeMap` 单一来源。
- 路径 B：一次性迁移全部旧日志（破坏 `~/.trha/sessions` 旧档回放，违背不删/兼容原则）。
- 决策：A。

## Step 3 · 任务原子分解（执行顺序 + 验收点）

### 组 A · 事件与持久化（对齐 event-producer-consumer / persistence-catalog）
- ✅ T1 `Core.Transcript` 信封：写入 `{v,id,ts,type,payload}`（保留扁平字段），读取兼容旧行 → 证据：182/182；真会话 5/5 行 `v:1`；16 个旧档回放正常
- ✅ T2 事件类型注册表：`EventKind`(7)/`eventRegistry`/`legacyEventName` 迁移点 → 证据：registry 单测（唯一/全覆盖/别名）
- ✅ T3 「模型可见即记录」：编排每轮 `queryModel` 前 emit `agent:model-request`；CLI 记录 `model-request` → 证据：E2E 4 次模型请求 = 4 事件且收敛
- ✅ T4 `docs/architecture/event-matrix.md`：事件生产者/消费者/持久化矩阵 → 证据：与 grep 全事件清单一致

### 组 B · 工具管线与防御（tool-execution-pipeline / tool-catalog / defensive）
- ✅ T5 工具服务化：`ctx.tools`（list/execute，能力 tools:list/execute）→ 证据：`/api/services` 返回 5 服务含 tools
- ✅ T6 工具 schema 目录：`src/Server/toolCatalog.ts`（单一来源 + toToolSpecs/findTool）→ 证据：catalog 单测（TS 89/89 含 +5）
- ✅ T7 防御硬化：`toolGuard.confineWritePath`（realpath 拒 symlink 逃逸）+ `limitOutput`(64 KiB) → 证据：guard 单测（越界/逃逸/截断）

### 组 C · 能力缝与文档（architecture / capability-seams）
- ✅ T8 `docs/architecture/dsh-capability-seams.md`：「加 X → 机制」表（每行 grep 抽查存在；不在本架构缝如实标注）
- ✅ T9 sessions 服务键：`ctx.sessions`（get/has/list）→ 证据：`/api/services` 含 sessions（sessions:get/list）

### 组 D · 目录化收尾（config-catalog / agent-lifecycle）
- ✅ T10 `settings-schema` JSON 导出：`trha settings-schema` 输出 15 键（key/kind/description/default）→ 证据：冒烟 15 行 JSON；单测字段对齐
- ✅ T11 `docs/architecture/agent-lifecycle-notes.md`：turn/round/工具展开图 + 概念对照 + 遥测缺口标注

## Step 4-9 工作法（执行记录）
- 每原子单测先行 → 全量回归（最终 Haskell 182 / TS 89）→ E2E 附证据
- 对抗性自检执行点：T7（symlink 逃逸）与 T3（模型请求可观测）均有单测攻击路径
- 状态更新日期：2026-09（北京时间）；遗留候选（非阻塞）：内核 HTTP 层事件化、`settings --json` 与面板热应用打通
