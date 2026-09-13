# 归档：`trha-orchestration`（原 `library trha-orchestration`）

**归档日期**：2026-09-13（北京时间）
**归档决定**：所有者裁定「A. 归档出构建」（保留代码，移出内核构建）
**原路径**：`src/Orchestration/{Bridge,Parallel,Subagent}/`
**原 stanza**：`trha.cabal` 的 `library trha-orchestration`（已删除）

---

## 1. 一句话

一个**编译得过、但从来没有调用者**的库：6 模块 199 行，零 stanza 依赖、零 `import Orchestration.*`、零测试。

## 2. 归档前的实测事实

| 维度 | 实测 | 命令 |
|---|---|---|
| 体量 | 6 模块 / 199 行（Bridge 81、Subagent 71、Parallel 47） | `find src/Orchestration -name '*.hs' \| xargs wc -l` |
| 被依赖 | **0** 个 stanza | `grep -n "trha-orchestration" trha.cabal` |
| 被 import | **0** 处 | `grep -rn "^import.*Orchestration\." --include=*.hs src test packages` |
| 测试 | **0** 条 | `test/Spec.hs` 中无 Orchestration |
| 能否编译 | ✅ 能（`ORCH_EXIT=0`） | `cabal build trha-orchestration` |

**结论**：它既不是「空库」，也不是「已实现未接线的高价值能力」（后者如 CPU 原生推理：有 M1–M20 真实实现 + 全绿测试）。它是**只有类型骨架、没有实现内容的遗迹**。

## 3. 逐块评估（为什么没有留下）

### ① `Bridge.Types` / `Bridge.HTTP`（81 行）—— 设计意图真实，**实现是假的**

```haskell
queryModel bridge req =
  post (bridgeHTTP bridge) "/api/query" (T.pack $ show (queryMessages req))
  --                                     ^^^^^^^^^^^^^^^^^^^^^^^^
  --                                     发的是 Haskell 的 show 语法，不是 JSON；
  --                                     对端（TypeScript）无法解析。

verifyType bridge req = do
  result <- post (bridgeHTTP bridge) "/api/verify" body
  case result of
    Right response -> return $ Right $ VerifyResponse True Nothing
    --                                   ^^^^^^^^^^^^^^^^^^^^^^^^
    --                                   丢弃服务端响应、且**无条件**报「类型验证通过」
    Left err -> return $ Left err
```

⚠️ **如果有人接线前不先修这一段，会得到一个恒返回 `True` 的「类型验证」函数** —— 这比删掉它更危险。这是本次归档最需要留档的一点。

### ② `Parallel.Types` / `Parallel.Scheduler`（47 行）—— 对 `async` 的平凡包装

- `parallel  = mapConcurrently id`
- `pipeline = foldl (\acc stage -> acc >>= stage) (return initial)`
- `mapReduce = mapConcurrently mapper` + reducer

无任何 trha 特有语义（无 GF(27)、无十二律相位、无约束推理）。另有死 import：`Control.Concurrent.STM` 未使用。

### ③ `Subagent.Types` / `Subagent.Manager`（71 行）—— 与内核已有能力重叠

- `spawnSubAgent` 只往 `IORef (Map String SubAgent)` 塞一条 `SubAgentIdle` 记录 —— **不启动任何东西**，此后状态永不改变；
- `terminateSubAgent` 只删表项；
- 内核**已有** `Core.Agent.Types` + `Core.Agent.StateMachine`；
- 类型用 `String` 而非项目通行的 `Text`（`SubAgentError String`）。

## 4. 架构理由（这才是归档的根因）

按 2026-09 所有者裁定（见 `docs/plans/plan-reconciliation.md`）：

> 内核 = **无状态协议/执行引擎，不持决策态**；plan / approval 归**外壳-编排层**；
> 内核由外壳派生（stdout 一行版本化 JSON 握手 + stdin 租约 + 日志 stderr）；
> `/_studio/` 一条路由。

`trha-orchestration` 作为**内核内的编排库**，正好落在被划走的那一侧 —— 它的存在本身与该裁定冲突。而它想做的三件事，现在都已由别处真做掉了：

| 它想做的 | 现在由谁真做 |
|---|---|
| TypeScript ↔ 内核 桥 | CLI 的 `trha serve`：`/v1/chat/completions`（OpenAI 兼容）+ SSE + `/_studio/` 路由 |
| 子代理 / 编排 | 外壳侧（TS 全功能编排 —— 所有者愿景所归；TS scheduler 已有 115 用例） |
| 并行调度 | 通用库（`async` / `stm`），与内核职责无关 |

## 5. 保留未动的部分

- **`src/Infrastructure/Network/HTTP.hs` 保留在 `src/` 下**：它是 `library trha-infra` 的 **exposed-module**（属 infra 层，分层正确），原先只是被 `trha-orchestration` 借用列进 `other-modules` 以便 `Bridge.HTTP` import 它。归档 orchestration 后它仍是 infra 层的公开模块，**不是** orchestration 的代码。
  （附带观察，未处理：它的 `get`/`post`/`put`/`delete` 返回 `T.pack $ show responseBody`，即把响应体做了 `show` 字符串化而非返回原始 body；与本次归档无关，留作后续评估。）

## 6. 如何取回

```bash
cd /home/yanli/work/trha
git mv archive/orchestration/Bridge   src/Orchestration/Bridge
git mv archive/orchestration/Parallel src/Orchestration/Parallel
git mv archive/orchestration/Subagent src/Orchestration/Subagent
# 再把下面这段加回 trha.cabal（原来在 library trha-infra 之后）：
#
# -- Orchestration Layer (TypeScript bridge)
# library trha-orchestration
#   exposed-modules:  Orchestration.Bridge.Types, .Bridge.HTTP,
#                     .Parallel.Types, .Parallel.Scheduler,
#                     .Subagent.Types, .Subagent.Manager
#   other-modules:    Infrastructure.Network.HTTP
#   hs-source-dirs:   src
#   build-depends:    base ^>=4.22, trha-core, trha-infra, text, aeson,
#                     servant, servant-server, tagged, warp, containers,
#                     stm, async, bytestring, http-client, http-client-tls,
#                     http-types
#   default-language: Haskell2010
```

Git 历史同样可用：`git log --follow archive/orchestration/Bridge/HTTP.hs`。

**取回前请先读 §3①** —— `verifyType` 的恒 `True` 必须先修掉。
