# 用仓颉替代 Haskell：可行性分析（含两处自我更正）

> **日期**：2026-09-21 ｜ **编译器实测**：Cangjie `1.3.0-alpha.20260919003053`（nightly）
> **探针**：`docs/reference/cangjie-typing-probes/`（`bash run.sh`，9/9 断言）
> **一句话**：**技术可行，且代价比初判小一个量级**；但**"网络性能"不是仓颉能解决的问题**（它每核比 Go 低 20–45%）。

---

## 0. 先更正两处初判错误

| 初判 | 实际 | 错因 |
|---|---|---|
| "仓颉生态为零，没有可借力的第三方库" | **GitHub 上 `language:Cangjie` 有 712 个仓库**；且有 Agent 框架、web 框架、FFI 生成器、GUI 框架 | 用 GitHub 搜 "cangjie benchmark" 就下结论，**明知仓颉托管在 GitCode 却没把这个因素用到生态判断上** |
| "没有 HTTP 框架 / FFI 要手撸" | `tang`（web 框架）、`cjbind`（**自动生成 C→仓颉 FFI 绑定**） | 同上 |
| "仓颉缺类型论，表达不了类型级抽象" | **幻影类型范畴隔离实测完全可用** | 见 §2；且未核查内核**实际**用了多少 GHC 独有能力（见 §3） |

---

## 1. 仓颉生态：有，但年轻

```bash
curl -s 'https://api.github.com/search/repositories?q=language:Cangjie&sort=stars&order=desc&per_page=40'
# total_count = 712；最高 star 151
```

| 项目 | star | 性质 |
|---|---:|---|
| `SunriseSummer/CangjieGUI` | 151 | 跨平台声明式桌面 GUI 框架（对标 Electron 的仓颉方案） |
| `cjbind/cjbind` | 32 | **自动生成 C 库 → 仓颉 FFI 绑定**（对 wgpu-native 那层直接相关） |
| `cangjie_stdx` | 6 | 官方扩展标准库 |
| `ystyle/cjvs` | 6 | 版本切换工具 |
| `CangjieBench` | 5 | 基准测试 |
| `ystyle/tang` | **4** | 轻量级 web 框架 |
| `LiuxyX/CjAgent` | 3 | agent 项目 |

**最重要的**：**Cangjie Magic**（2025-03 发布，`gitcode.com/Cangjie-TPC/CangjieMagic`）——
"首个基于仓颉原生构建的 LLM Agent 开发平台"，含 **Agent DSL + 原生 MCP 支持 + 智能调度引擎 + RAG + 多智能体协作**。
另有配套"RAG 基座 + Agent 框架 + 自动化平台"工具链。

**注意成熟度**：GitHub 侧最高 151 star；`tang` 只有 4 star。**存在 ≠ 成熟**，用它替 Warp/Servant 要有准备。

---

## 2. 仓颉类型系统能力（编译器实测，非查文档）

完整结果与编译器原文见 `cangjie-typing-probes/README.md`。摘要：

| 能力 | 结果 |
|---|---|
| 约束泛型 + F-bounded 多态 | ✅ |
| **幻影类型范畴隔离** | ✅ **支持**（跨范畴混用被编译器拒绝） |
| 泛型枚举 + 模式匹配 | ✅ |
| **高阶类型 HKT** | ❌ |
| **关联类型** | ❌ |
| **GADT / 索引类型** | ❌ |
| **类型级 / 依赖类型参数** | ❌ |
| STM / TVar | ❌（有 `Mutex`/`Condition`/`Semaphore`/`Atomic*`/`SyncCounter`） |
| **原生 effect handlers** | ✅（官方自认"实验性"，InfoQ 2026-05-11；**本分析未实测**） |

**档位**：≈ **Rust**（ADT + 模式匹配 + 约束泛型 + 幻影类型），**低于 GHC 一档**。

---

## 3. 决定性依据：内核**实际**依赖 GHC 多少

```bash
# 全内核用到的语言扩展
grep -rhoP '^\s*\{-#\s*LANGUAGE\s*\K[^#]+' src | tr ',' '\n' | sed 's/^ *//' | sort | uniq -c | sort -rn
```

| 扩展 | 文件数 |
|---|---:|
| OverloadedStrings | 49 |
| ScopedTypeVariables | 8 |
| ForeignFunctionInterface | 4 |
| DeriveGeneric | 4 |
| **TypeFamilies** | **3** |
| ExistentialQuantification | 2 |
| **DataKinds** | **1** |
| **TypeOperators** | **1** |
| **GADTs / PolyKinds / RankNTypes / UndecidableInstances** | **全部 0** |
| **`type family`** | **0 处** |
| **`class`** | **全内核仅 2 处** |

**这 2 处 `class`、3 处 `TypeFamilies` 全在同两个文件里**：

```bash
grep -rn '^class ' src                  # → 仅 src/Infrastructure/WebGPU/Raw/Types.hs:137,146
sed -n '135,155p' src/Infrastructure/WebGPU/Raw/Types.hs
#   class Handle a where
#     type ObjectOf a :: Type      ← 唯一真用到的关联类型，在 FFI 层
```

**"GADT 语法"的 3 处命中全是注释里的 Agda 代码**（`-- > data PolarRep : Set where`），是溯源引用。

**`SovereignTypes.hs`（★核心，341 行）的手法**（其自身模块注释原文）：

> "为每个范畴定义**独立类型**，构造子**不导出**，只走 smart constructor，使不变量（值域）由构造保证，混淆在编译期就被拒绝"

= `newtype`（28 处）+ `Proxy`（18 处）+ 智能构造子 → **正是 §2 实测在仓颉里可行的那套。**

### GHC 独占面收敛为三小块

| 独占点 | 规模 | 仓颉对位 |
|---|---|---|
| **Free monad 插件 DSL**（唯一真 HKT 依赖） | `Core/Plugin/{Free,Types}.hs` 2 模块 | ⭐ **原生 effect handlers**。该 DSL 的构造子（`RegisterService`/`SubscribeEvent`/`ProvideEffect`/`WithContext`）**本来就是"效果"，`execPlugin` 本来就是"效果处理器"** |
| **关联类型** | 3 文件（FFI 层，1 个类） | `cjbind` 自动生成绑定，**该层不用手移** |
| **STM / TVar** | 3 文件（`Core/Agent/{Types,StateMachine}.hs`、`API/Server.hs`；TVar 10 处 / `atomically` 4 处） | `Mutex` + `Atomic*` 等价替换（该处**无多变量事务**） |
| ★核心范畴隔离 | `SovereignTypes.hs` 341 行 | ✅ **实测可行** |

---

## 4. 修正后的结论

**「用仓颉替代 Haskell」技术可行，代价比初判小一个量级。** 初判的"会丢掉类型级抽象，而那是核心"**不成立** ——
内核核心手法是 `newtype` + 幻影参数 + 智能构造子，**不是类型级编程**；类型级编程只出现在**一个 FFI 层**（可自动生成）和**一个插件 DSL**（有原生对位）。

### 但仍然成立的四条（都有硬证据）

1. **网络性能仍是反向选择**：每核比 Go **低 20–45%**（64 B / 512 B / 4 KB / 16 KB × 200/800 连接全格，独立手写 C 作参照；详见 `/data/training/cli/netbench-go-cj/README.md`）。**若"网络性能"是目标，仓颉比已选的 Go 更差。**
2. **最关键的架构模式押在实验特性上**：替代 Free monad 的那条路是 **effect handlers**，而官方自认它 *"still considered an actively developed, experimental part of the language"*。
3. **语言是 alpha**：本机 `1.3.0-alpha` nightly；公开版最高 LTS 1.0.5 / STS 1.1.3。探 API 时连续踩到：构造函数不 `connect`/`bind`、`read` 无偏移参数、`ArrayList` 无 `append`、`println` 非 TTY 不刷新、`Console` 已废弃。
4. **greenfield**：`src/` **11,497 行 + 6 个 cabal library** 全部重写；本仓在此分析前 `.cj` 文件数 = **0**。

---

## 5. 必须分清：(A) 换语言实现内核 ≠ (B) 用 Cangjie Magic 替代 trha

- **(A) 换语言实现内核** —— 把约束层 + 推理层用仓颉重写。**本文分析的就是这个，可行。**
- **(B) 用 Cangjie Magic 替代 trha** —— Cangjie Magic 是**通用** agent 框架（Agent DSL / MCP / RAG / 多智能体），而这些能力 **trha 的 TS 编排层已经具备**。用它替换 trha 会**丢掉 trha 唯一独特的东西**（形式化约束层 + 原生三值推理），换来的是已经有的东西。**不划算。**

---

## 6. 最小可行实验（建议顺序，不要一次性动内核）

1. **移植「约束层」**：把 `ConstraintVerdict` + `t6Verify` + `causalGraphStep` + `wuxingForward` 用仓颉重写。
   这一层只需**幻影类型 + ADT + 模式匹配 + 约束泛型** —— §2 实测全部支持，**恰好避开仓颉的三个短板（无 HKT/GADT/STM）**。
2. **验收方式**：沿用 trha 现有 `test-cpu/Spec.hs` 那套"以 Agda 权威文件为注释出处、逐条对拍"，**比较 Haskell 版与仓颉版对同一批输入的输出是否逐元素一致**（正好用上 C3 判据"跨实现相等"）。**这是可自动判定的。**
3. **只有第 1–2 步给出"输出一致 + 代码量可控"的硬数据**，再讨论插件层（effect handlers）与 STM 的替换。
4. **网络性能单独处理**：不是语言问题。先量生产桥（`packages/scheduler/src/Bridge/Haskell.ts` ↔ 内核 HTTP/SSE）到底哪个指标不够，再考虑 Unix domain socket / 二进制帧 / 消除边界。**换语言不解决它。**
5. **若目标是"内核自带推理更快"**：那是**数据布局**问题（222 s/token 来自每 token 重读 `.sov` + 重解包 300 块权重，纯计算仅 ~18 s）。**换语言不解决，`Data.Vector.Unboxed` 紧凑化（~2GB）才解决。**

---

## 7. 本文核实不了的

- **`Cangjie Magic` 的成熟度只有二手描述**（OSCHINA / AITOP / CSDN 通稿，`opencangjie.net` 抓取失败）。**未拿到其仓库活跃度、真实代码量、测试覆盖。** 请以实际拉取的仓库为准。
- **`tang` / `cjbind` / `CangjieGUI` 只看 star 与描述，未读代码。** 存在 ≠ 成熟。
- **effect handlers 完全未实测**（仅引 InfoQ）。它是替代 Free monad 的**单点依赖** —— **建议先写一个最小的 effect-handler 插件原型验证它**，再谈方案。
- 仓颉生态数据取自 GitHub（712 仓库）；**GitCode 侧的真实规模本文没有可靠计数**。
