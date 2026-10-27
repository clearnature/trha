# trha 架构与技术栈审查（第三方独立复核）

> **日期**：2026-09-21 ｜ **性质**：外部复核（非项目自评）。所有结论都附**可复现命令**。
> **复核对象**：commit `5eb5dee`（2026-09-19 工作树，含 67 项未提交改动）
> **与项目自评的关系**：本文**不重复** `architecture/architecture-intended-vs-actual.md` 的 D-1…D-9 与状态分档。
> 那份是**项目自己的**（且质量很高）；本文是**独立核出来的、它没写的东西**。
>
> ⚠️ 本文的判据是**工程可维护性**，与项目的 C1–C5 判据（数学正确性）**不同**。两者不冲突，但不要混用。
>
> **2026-10-27 注**：项目仍在开发中。本文多处使用的「死代码」一词，按各模块的规划出处应读作**「未接线」**——
> `Presentation/` 有 `architecture/presentation-layer.md`、`Core.Plugin` 有 `architecture.md §3.1`、
> `sdk`/`haskell-network` 是 `project-overview.md:66` 记录的独立构建包。真正的「无规划出处」只有
> `packages/go-haskell-bridge` 已于 2026-10-27 **归档到 `archive/go-haskell-bridge/`**（原计划复用 Reasonix 的 Go 桥，现不需要）。
> 详见 `plans/improvement-plan-2026-10-27.md` §0.1。

---

## 0. 结论摘要

| # | 发现 | 严重度 | 是否被项目文档记录过 |
|---|---|---|---|
| S1 | **41 个模块被两个 library 各编译一份** = 41 处「同名不同类型」 | 🔴 高 | 记录过**一次事故**，但**规模没量化**；且已决定不修 |
| S2 | **约 13,600 行 Haskell 在构建之外**（占全项目 Haskell 的 ~43%），其中 499 行**任何方式都构建不了** | 🔴 高 | 只记了 `sdk`「需单独 build」，**未记 haskell-network / go-haskell-bridge** |
| S3 | **`packages/go-haskell-bridge` 是无人引用的通用 IPC 脚手架**（906 行 Go + 499 行 Haskell） | 🟠 中 | **未记录** |
| S4 | `Presentation/**` 8 文件 / 306 行 = 死代码 | 🟡 低 | 记录过（"从未参与编译"），**未量化** |
| S5 | **36 个 executable + 3 test-suite**，探针通过/失败**不聚合成 exit code** | 🟠 中 | **未记录** |
| S6 | 「性能不是判据」被用在**它不成立的地方**（"大脑" 222 s/token） | 🟠 中 | 数字记录过，**判据矛盾未指出** |

**一句话**：技术路线**原创且自洽**；但**当前可用价值 ≈ 一个普通 agent harness**，而项目投入最多的差异化部分（约束层 + 原生推理）**尚在可用性边界之外**。最大的工程风险不是"做得不对"，而是**43% 的代码不在任何门禁内**。

---

## 1. 已核实的构建拓扑

```bash
# 根构建只含两个包
cat cabal.project                      # → packages: .  packages/app/CLI
grep -cE '^(library|executable|test-suite)' trha.cabal   # → 45 个节
```

| 项 | 实测 |
|---|---|
| `cabal.project` 包含的包 | **仅 2 个**：`.` 与 `packages/app/CLI` |
| library | **6 个**：`trha-core`(13 exposed) / `trha-llm`(34) / `trha-api`(5 exposed + **41 other**) / `trha-infra`(5) / `trha-webgpu`(9) / `trha-gpu-infer`(1, `hs-source-dirs: gpu-infer`) |
| executable | **36 个**（其中 `benchmarks/webgpu` ×10、`benchmarks/cpu` ×14 是探针） |
| test-suite | 3 个 |
| 共享 `hs-source-dirs: src` 的 library | 5 个（`trha-gpu-infer` 用独立目录 `gpu-infer`） |

---

## 2. S1：41 处「同名不同类型」（复核命令与结果）

```bash
python3 - <<'PY'
import re,collections
txt=re.sub(r'--[^\n]*','',open('trha.cabal',encoding='utf-8').read())
mods=collections.defaultdict(list)
for m in re.finditer(r'^library\s+(\S+)([\s\S]*?)(?=^library\s|\Z)', txt, re.M):
    lib,body=m.group(1),m.group(2)
    for key in ('exposed-modules','other-modules'):
        mm=re.search(rf'^\s*{key}:([\s\S]*?)(?=^\s*[a-z][\w-]*:|\Z)', body, re.M)
        if mm:
            for l in mm.group(1).split('\n'):
                if l.strip(): mods[l.strip()].append(lib)
dup={k:v for k,v in mods.items() if len(v)>1}
print(f'总模块条目 {len(mods)}，被 >1 个 library 声明: {len(dup)}')
for k,v in sorted(dup.items())[:12]: print(f'  {k:44s} -> {", ".join(v)}')
PY
```

**实测输出**：`总模块条目 87，被 >1 个 library 声明: 41`

```
Core.Agent.StateMachine            -> trha-core, trha-api
Core.Session.Manager               -> trha-core, trha-api
Infrastructure.CPU.Christoffel     -> trha-llm, trha-api
Infrastructure.CPU.ConstraintVerdict -> trha-llm, trha-api
... 共 41 条
```

`trha-api` 的 **`other-modules` = 41 条**，装的正是这些重复副本 —— 它不依赖 `trha-core`/`trha-llm`，而是**自己再编一份**。

### 为什么这与项目自己的判据冲突

项目已记录过一次真实事故（`Infrastructure.CPU.GGUF` / `Dequant` 同时在两个库 → *"two incompatible types of the same name"*），也记录了删掉 `other-modules` 就 `undefined reference` 的链接失败。**决定不修**，理由是：

> "动议理由是消除重复编译，但那影响**构建时间** —— 本项目判据是数学/理论正确性，构建时间不是判据"

**本文的判断：这个理由站不住。** 重复编译的真正代价**不是构建时间，是类型标识分裂** —— `trha-api` 与 `trha-llm` 里的 `LLMAdapter`、`Core.Session.Manager` 各自是**两个不同类型**。**"同名不同类型"是类型正确性问题，落在 C1–C5 第一条判据（编译期类型不变量）里。** 用"性能不是判据"豁免一个类型正确性问题，是拿对了判据、用错了地方。

（`architecture-intended-vs-actual.md` §6b 的"已评估决定不做"列了三条理由，其中②"未验证它是否仍阻碍任何该做的事"——**本文正是那个验证：它阻碍的是类型唯一性**。）

---

## 3. S2：构建外代码（复核命令与结果）

```bash
for n in sdk haskell-network go-haskell-bridge; do
  printf '%-20s %4s 文件 %7s 行  根构建引用: %s 次\n' "$n" \
    "$(find packages/$n -name '*.hs' | wc -l)" \
    "$(find packages/$n -name '*.hs' -exec cat {} + | wc -l)" \
    "$(grep -c "$n" cabal.project trha.cabal | awk -F: '{s+=$2} END{print s}')"
done
```

| 目录 | 规模 | 在根构建中被引用 | 能否独立构建 |
|---|---:|---:|---|
| `packages/sdk` | **15 文件 / 1,059 行**（2026-10-27 复核；旧值 92 文件 / 11,781 行含 `dist-newstyle`） | **0 次** | 有 `trha-sdk.cabal` |
| `packages/haskell-network` | 19 文件 / 1,306 行 | **0 次** | 有 `gh-haskell-network.cabal` |
| `packages/go-haskell-bridge` | 9 文件 / 499 行（Haskell 侧） | **0 次** | 有 `haskell/gh-haskell-go-bridge.cabal`（嵌套） |
| `packages/app/Desktop` | TS 11,180 行 | 0 次（走 npm） | — |
| **合计 Haskell** | **~13,586 行** | **0** | — |

**占全项目 Haskell 约 6%**（2026-10-27 复核更正：sdk 真实源码 15 文件 / 1,059 行；旧值 11,781 行把 `dist-newstyle` 计入）（分母 `src/` 11,497 + app 6,322 + sdk 11,781 + network 1,306 + bridge 499 ≈ 31,405）。

**最刺眼的是 `packages/sdk`：1,059 行（2026-10-27 复核），不在构建、不在 CI、不在类型检查内。** 一个「类型驱动设计」的项目里，体量最大的那部分不受类型检查 —— 这不是技术债，是**门禁失效**。

---

## 4. S3：Go 桥是**无人引用的通用脚手架**（项目文档未记录）

```bash
grep -rn --include='*.hs' --include='*.ts' --include='*.cabal' \
  -iE 'go-haskell-bridge|goBridge|haskellBridge' src packages trha.cabal cabal.project scripts \
  | grep -v '/go-haskell-bridge/'
```

**实测**：唯一命中是 **`packages/scheduler/src/Bridge/Haskell.ts`** —— 那是**另一条桥**（TS ↔ 内核的 OpenAI 兼容 HTTP/SSE，222 行，**有 vitest 用例、在生产的**），与 Go 桥只是**重名**。
`src/`、`trha.cabal`、`cabal.project`、`scripts/` 对 Go 桥**引用 0 次**。

| 项 | 实测 |
|---|---|
| Go 侧 | **906 行 / 9 文件**：`http/server.go`(137) `grpc/server.go`(82) `channel/manager.go`(113) `memory/manager.go`(152) `protocol/protocol.go`(125) `error/handler.go`(107) `main.go`(75) `goroutine/pool.go`(64) `serializer/serializer.go`(51) |
| Haskell 侧 | 499 行 / 9 文件 |
| 业务逻辑 | **零** —— 全是通用 IPC 组件（HTTP/gRPC server、channel、goroutine pool、memory manager、serializer） |
| 自己的 README | **已与代码不一致**：写 `go/protocol/handler.go`，实际是 `protocol/protocol.go` → 建完未再维护 |
| 被引用 | **0 次** |

**判断**：这是一份**通用「Go↔Haskell 进程间桥」脚手架**，创建后未接线、未维护、无基准。
**建议**：要么补齐 `.cabal` 纳入构建 + 说明**为什么需要 Go**、服务哪个具体指标；要么**归档/删除**。
在明确它解决哪个指标之前，讨论"用仓颉替换它"没有意义。

---

## 5. S4/S5：死代码与构建目标爆炸

**S4 死代码**：`grep -c Presentation trha.cabal` = **0**，`cabal.project` = **0**；`src/Presentation/` 8 文件 / 306 行从未参与编译。

**S5 构建目标**：**36 个 executable + 3 test-suite**。其中 24 个是探针（`benchmarks/webgpu` ×10 用于真机 GPU 对拍、`benchmarks/cpu` ×14）。

这是**有意的取舍**：每个探针是独立二进制，能单独在真 GPU 上跑 —— 对「数学正确性」判据是合理的。
**代价**：CI 要编 39 个目标；**探针的通过/失败不聚合成 exit code**（靠人看输出）。
**建议**：加一个聚合 runner，把「人工看输出」变成一条 exit code。这不动判据，只补门禁。

---

## 6. S6：「性能不是判据」被用到了它不成立的地方

C1–C5 明确写 *"Performance is explicitly not a criterion"*。

- 对**约束层**（T⁶ / 因果图 / 五行链）**成立** —— 约束的正确性与速度无关。
- 对**「大脑」（本地三值推理）不成立** —— `architecture-intended-vs-actual.md` §0 自己记录：
  *"60 层单 token 流式 ≈ 222s（每 token 重读 .sov + 重解包 300 块权重；纯计算仅 ~18s），整包装箱 ~40GB 超本机 32GB commit 上限"*。

**222 s/token 不是"草稿质量"，是完全不可用。** 判据一刀切 → 这一支长期无性能门禁 → 欠债累积到"要么改数据布局（紧凑数组 ~2GB）要么这条支线废掉"。
**建议**：**判据分层** —— 约束层不设性能门；推理层必须设（哪怕很宽松）。

---

## 7. 技术栈逐项评价

| 选择 | 评价 | 理由 |
|---|---|---|
| **Haskell 作内核** | ✅ **内在一致** | 核心诉求是"类型论约束"，Haskell 类型系统是其载体。代价（生态为零、要自写 tokenizer/GGUF/SOV3/反量化/wgpu FFI）是**买来的**：换 Python + llama.cpp 就会被迫接受 llama.cpp 的简化，而《架构宪法》明说"数学结构不可简化" |
| **TypeScript 作编排** | ✅ 正确 | Express/Zod/SSE 生态、115 vitest 用例、stateStore 原子写+启动恢复 |
| 曾有两套编排 | ⚠️ 已收敛 | Haskell 侧 199 行已归档出构建 |
| **Electron 作外壳** | ⚠️ **栈内哲学矛盾** | 内核追求 Alpine+musl→scratch 单文件静态二进制（几 MB），外壳 Electron 实测 **430 MB**（`/opt/trha`）。不建议现在换（外壳不是核心），但应在文档里明写这个矛盾 |
| **WGSL / wgpu-native FFI** | ✅ 最实在的一块 | 真机对拍 + 已接生产（`TRHA_GPU=1`，353ms/60 层 ≈5.1× CPU，hidden 与 CPU 逐元素一致） |
| **Go-Haskell 桥** | ❌ 见 §4 | 无人引用、无基准、用途未说明 |
| **36 个探针** | 🟡 见 §5 | 取舍合理但缺聚合 |

---

## 8. 建议优先级

1. **处置构建外代码（~13.6k 行，占 43%）** —— `sdk` 进构建或删；`haskell-network` 明确去留；`go-haskell-bridge` 归档或补构建。**这是最大风险敞口。**
2. **修那 41 个重复模块** —— 理由**不是构建时间，是类型标识唯一性**（项目自己的第一条判据）。
3. **给「大脑」设一条性能门禁**，并把"性能不是判据"**限定到约束层**。
4. 删 `Presentation` 死代码。
5. 给 36 个探针加聚合 runner。

**不要做**：① 为了"像主流 agent 框架"去补 MCP/工具生态（差异化在约束层，编排已由 TS 补齐）；② 现在换掉 Electron（纯成本）。

---

## 9. 本文核实不了的

- **`222s/token`、`40GB 装箱`、`353ms/60层 ≈5.1×` 是项目自己的记录，本文没有跑。** 核实的是"它们被写在文档里"，**不是"数字正确"**。跑它们需要 `.sov` 模型和很长时间。
- **`cabal build all` 是否真能过，本文没跑**（GHC 9.14.1 / cabal 3.17 已在位，但全量构建耗时长）。
- **`packages/sdk` 那 1,059 行（复核后）的代码质量，本文只看了行数**，未读实现。
- 本文核实的是**构建拓扑与模块归属**（cabal 文件解析 + grep 计数），这部分是硬事实。
