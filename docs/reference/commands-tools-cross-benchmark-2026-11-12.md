# 命令与工具跨实现对标：七方源码审计（2026-11-12）

> **目的**：回答两个问题——(1) trha 的 91 条斜杠命令与 107 个工具，哪些只有名字没有代码；(2) 六个参考实现的命令/工具规模、分组与交互层级是什么样，trha 处在什么位置、该吸收什么。
> **方法**：七路并行源码审计（6 个参考仓库 + trha 本地普查），全部结论带 `file:line` 证据；本文件是综合层，逐条普查表见 §2（trha）与各分节（参考实现）。
> **对标对象**：`~/work/deepseek-harness`（dsh）、`~/work/DeepSeek-Reasonix`、`/data/training/cli/oh-my-pi`、`/data/training/cli/opencode`、`/data/training/cli/qwen-code`、`/data/work/functional-programming/hs`（haskell-agent / langchain-hs / tricorder）。
> ⚠️ 参考仓库是移动的 checkout，行号以审计当日为准；结论级别的事实（数量、分组结构、stub 状态）稳定性高于行号。

---

## 1. 数字对比总表

| 实现 | 斜杠命令 | 工具 | 功能分组 | 「注册即实现」纯净度 |
|---|---|---|---|---|
| **trha** | **91**（10 组） | **74 catalog + 33 extra = 107** | ✅ 唯一 100% 功能分组 | 81 实现 + 10 部分 / 工具全实现 |
| deepseek-harness | 8（Host 6 + Web 本地 2） | 目录 76/71 名；standard 预设 31 | ❌（菜单 add/commands 两段） | ✅ 0 stub |
| DeepSeek-Reasonix | 内核 33 + TUI 本地 20 = 53 动词 | 62 固定名（31 编译期 + 5 条件 + 26 装配）+ MCP/插件动态 | Kind 分类 5 种 | ⚠️ CLI 注册表 3 条无执行器 + 双目录漂移 |
| oh-my-pi | 会话内 89 + CLI 顶层 56 | 30 builtin + 3 hidden | ✅ 7 组 | ✅ 0 stub |
| opencode | TUI palette 90（带斜杠形式 27）+ server 2 | 19 定义（默认可用 12） | ❌（键名空间式） | ✅ 0 stub |
| qwen-code | 70 内置 + 11 别名 | ToolNames 49 名（48 有实现） | /help 按来源 6 组 | ⚠️ 1 幽灵（`save_memory`） |
| haskell-agent | 67（Catalog + ReplAction 类型穷尽） | ~45（typedTool decoder DSL） | ❌（dialect 门控） | 99%（1 处显式降级） |

规模定位：trha 命令数第一（91）、工具数第二（107，仅次于 Reasonix 的动态命名空间）；纯净度好于 Reasonix/qwen-code，逊于 dsh/pi/opencode/haskell-agent 的满分。**修正一处旧口径**：tool-catalog.md 写「共 74」是对的（60 个多行条目 + 14 个单行条目），此前对话中「60」的数法漏了单行条目。

## 2. trha 实现普查（本地审计结论）

### 2.1 斜杠命令：81 实现 / 10 部分 / **0 仅名字**

唯一来源 `packages/app/CLI/UI/Commands/Registry/Table.hs:25-115`（91 条 SlashCommand，纯数据表）；解析 `Registry/Parser.hs:32-155`（91 条全有分支，另有隐藏命令 `/mouse` 不入册）；执行 `Commands/Env.hs:44 dispatch` = 7 个领域模块认领（Meta/Model/Session/Config/Integration/Tools/Plan）。**用户预设「很多只是名称没有代码实现」不成立**——但 10 条部分实现是真实的，且全部集中在 REPL 面（TUI 面均为真实现）：

| 命令 | REPL 面问题 | TUI 面 |
|---|---|---|
| /home | 恒定文案「Home is the TUI…」（Session.hs:160） | 真切 RouteHome |
| /copy、/verbose | 恒定文案（Tools.hs:80 / Config.hs:103） | 真复制 / 真切换 |
| /clear | 只 `clear` 清屏，与注册描述「清历史」不符（Session.hs:105） | 真清 appMessages |
| /sandbox、/provider | 只读提示 / 仅列表（Config.hs:177 / Model.hs:102） | 真面板 |
| /compact、/compress | `[focus]` 参数收下不用（Session.hs:251 `_focus`） | 同 |
| /vim | 开 $EDITOR 但结果不回填输入框（Plan.hs:215） | 无专分支 |
| /reload-plugins | 仅重扫本地 ~/.trha/commands，未调 API（Integration.hs:165） | 同 |

### 2.2 工具：74 catalog + 33 extra，**全部有执行体**

- 执行链：`packages/scheduler/src/Server/index.ts:1646 executeTool` → `canonicalToolName`（7 条 `TOOL_ALIASES` 旧名）→ `resolveTool` 注册表 → `runStandardTool` → `runExtraTool` → unknown。
- 41 个 standardTools + 33 个 extraTools（`extraTools.ts` 的 `bing`/`duckduckgo` 是 web_search 内部后端标签，不是工具）与 74 条 catalog **恰好互补，无重叠无遗漏**。
- 唯一轻实现：`exit_plan_mode` 返回 `WAITING_FOR_APPROVAL` 复用内核审批门（设计如此，S:690-693 注释）。

### 2.3 卫生债（三处）

1. **~40 个迁移占位空分支**：standardTools.ts:253-380、extraTools.ts:118-222、index.ts:1703-1735 的旧 if 链——`resolveTool` 永远先命中，全部是死代码。
2. `append_file` 缺 `toolDeclarations.ts` 声明行（73 声明 vs 74 工具；只影响 preset 元数据）。
3. 隐藏命令 `/mouse` 实现完整但不在 91 条注册表；`/stop` 的 Meta.hs:54-55 分支在两个表面主路径上均为死代码。

## 3. 参考实现分节摘要

### 3.1 deepseek-harness（dsh）——插件架构的极简命令面

- 命令：Cordis `commands` 服务注册表（`packages/interaction/commands/src/index.ts`，register/parseCommand/execute），Host 第一方 6 条（/goal /plan /feedback /compact /permission /export，各为独立插件包，含中文别名）+ Web 本地 2 条 = **8 条**；无 /help（发现由 ui-commands 弹层完成）。无分组字段。
- 工具：**npm 包 dsh-tool-\***，`ctx.tools.register(defineTool({name,parameters,execute}))`；目录 76 条目/71 名；standard 预设 31 个（`presets/standard.patch.yml` 声明式 patch）。执行经 `ToolExecutionPipeline`（prepare→dispatch→complete + `serviceAsk` 审批闸门）；沙箱 seam 覆盖 bwrap→Landlock / Seatbelt / Windows ACL（fail-closed）。
- **值得学**：审批进 pipeline 而非散在工具里；ScopedLayers 全局+per-agent 作用域遮蔽；预ets 是声明式 yml。

### 3.2 DeepSeek-Reasonix——规模最大，但有双目录漂移事故

- 命令：内核 catalog 33（`internal/session/control/slash_catalog.go`）+ TUI 本地 20 = 53 动词；**CLI 注册表 50 条是与内核 catalog 重复的第二份清单，生产代码只消费 1 条，且 /graph /browser /web 三条注册了却无任何执行器**（键入后 `answerUnresolvedSlash` 当普通消息发给模型）——双目录漂移的直接事故样本。
- 工具：62 固定名（编译期 `RegisterBuiltin` 31 + 条件声明 5 + 装配期 `wireTools` 26）+ MCP/插件动态命名空间。schema/执行接口级分离；可选 `Previewer`（写工具无副作用预演 diff 供审批）；执行入口 `executeOne` 过 policy/contextual/plan/delivery/permission/prepare/hooks 七道闸门。
- **值得学**：Previewer 审批预演、`use_capability` 单工具代理收窄 provider 可见面。**要防**：双目录漂移（trha 的 Table.hs 单一来源恰是解药）。

### 3.3 oh-my-pi——与 trha 最同构的分组法

- 命令：会话内 **89 条、7 个功能分组**（modes 21 / lifecycle 27 / session 20 / collaboration 11 / control 6 / marketplace 3 / skills 1），注册表 `packages/coding-agent/src/slash-commands/builtin-registry.ts`；双分发器 `handleTui`(79)/`handle`(47)；别名 9 条；动态命令 5 种来源。CLI 顶层另有 56 子命令。
- 工具：30 builtin + 3 hidden（think/yield/goal）；14 个 `createIf` 条件工厂（环境缺依赖返回 null，非 stub）。agent-loop 里 RESERVED_TOP_LEVEL_WORDS 防未注册管理动词泄给 LLM。
- **值得学**：7 组分组的粒度（trha 10 组的最近亲）；防泄漏护栏（RESERVED 名单）。

### 3.4 opencode——UI 命令与 server 命令的职责切分范本

- 命令：TUI palette 90 条（app 42 / session 33 / prompt 11 / plugins 4，键名空间式 `session.new`），带斜杠形式仅 27 条；server 端只有 2 条内置模板命令（/init /review）+ markdown/MCP/skill 动态。**UI 操作类命令在 TUI 进程内执行；只有命中 server 命令表的模板类才转发 `POST /session/:id/command`**——双表面不对称有明确语义。
- 工具：19 定义（默认 12 可用），条件注册 = 门控非 stub；`invalid` 哨兵工具向模型回报无效调用。
- **值得学**：双表面切分原则（正好治 trha 的 10 条 REPL 占位）；TUI→server 反向控制通道（tui-control 13 端点）。

### 3.5 qwen-code——每命令一文件 + 幽灵工具案例

- 命令：70 内置（`packages/cli/src/ui/commands/` 每命令一文件，BuiltinCommandLoader 聚合）+ 11 别名 + 6 类动态 loader；/help 按来源 6 组（非功能分组）；无功能分组字段。
- 工具：ToolNames 49 名，48 有实现；**`save_memory` 是幽灵**（常量在 `tool-names.ts:29`，无 MemoryTool、从不注册，权限模块还残留引用）——「常量在、实现无」的活案例。lazy factory + 权限门控注册（`createToolRegistry`）。
- **值得学**：两遍名称/别名匹配 + subCommands 递归（堆叠 skill 上限 5）；扩展命令冲突改名 `ext.name`。

### 3.6 haskell-agent / langchain-hs / tricorder——Haskell 侧的类型化谱系

- **haskell-agent**（同语言最强参考）：67 条 slash（`Catalog.hs` 注册表 + `ReplAction` **逐命令一个构造子，分发穷尽由编译器强制**——漏 handler 即编译失败）；~45 工具（`mkToolRegistry` 重名/名实不符**编译期拒绝**；`typedTool :: Text -> Decoder args -> (args -> IO …)` 在构造点恢复类型安全；schema 用小型 DSL 生成）。runtime daemon（Unix socket + supervisor）+ agent-server（~20 路由）。
- **langchain-hs**：纯库，0 命令；类型化在 `RunnableTree` GADT AST（Id/Prim/Lambda/Seq/Par/Branch/Fallback），工具本身是裸 Value schema（最弱端）。
- **tricorder**：CLI 7 条 + TUI 8 键；MCP 工具用 **TH reify 编译期强制**每个构造子的描述覆盖——漏一个即编译失败。
- **值得学**：编译期穷尽/一致性检查是 Haskell 对这类「注册表↔分发器」漂移问题的**结构性解法**，trha 有语言优势没用上。

## 4. 交互层级七方对比

| 层 | dsh | Reasonix | pi | opencode | qwen-code | haskell-agent | **trha** |
|---|---|---|---|---|---|---|---|
| UI | Web React + composer 管线 | bubbletea（serve 的 HTTP 客户端） | tui 包 + input-controller | SolidJS opentui | React ink | brick（App/Event/Reduce） | brick（Slash.hs + Commands/\*） |
| 命令注册 | Cordis commands 服务 | 内核 catalog + TUI 本地**两套** | builtin-registry（7 组） | keymap layer + palette | 每命令一文件 + 6 loader | Catalog + ReplAction 穷尽 | **Table.hs 单一来源 + Parser**（10 组） |
| 编排 | Host RPC session-controller | Controller.Submit + switch | AgentSession | HTTP API (Effect) | CommandService → core/turn | agent-server ~20 路由 | scheduler express /api/\* |
| 工具注册 | npm 包 + ScopedLayers | 编译期 + 装配期 | BUILTIN_TOOLS + createIf | 条件注册 | lazy factory + 门控 | **重名编译期拒绝** | defineTool + resolveTool |
| 执行管线 | **ToolExecutionPipeline** + serviceAsk | **executeOne 七道闸门** | executeToolCalls | 钩子 + 权限 ask | CoreToolScheduler 确认流 | dispatch + approval 字段 | executeTool 四级分发（无统一 pipeline） |

trha 的层间空隙：**没有统一执行管线对象**——审批闸门（内核 approve）与工具执行在 dsh/pi/Reasonix 都是带闸门的 pipeline，trha 分散在 executeTool 与各工具内部；沙箱层参考集已普遍内化（dsh 三平台 fail-closed），trha 沙箱尚在计划线（docs/plans/sandbox-*）。

## 5. 分组对比（trha 是唯一全覆盖者）

| 实现 | 分组方式 | 覆盖 |
|---|---|---|
| **trha** | 10 个功能语义组（会话/计划任务/模型/上下文记忆/工具服务/外观/权限设置/帮助…） | **91/91** |
| oh-my-pi | 7 个功能组 | 89/89 |
| qwen-code | /help 按来源 6 组（非功能） | 来源覆盖，语义无 |
| Reasonix | Kind 分类 5 种（builtin/command/skill/subagent/prompt） | 类型而非功能 |
| dsh / opencode / haskell-agent | 无功能分组 | — |

trha 的 10 组分组（`commands-grouping-draft.md` 定案）在参考集里粒度最细、覆盖最全；oh-my-pi 的 7 组是最近亲。这是 trha 的差异化优势，应保持并在 `/help` 渲染与 picker 中显式呈现组结构。

## 6. 五个可吸收洞见

1. **编译期穷尽检查**（haskell-agent）：91 条命令改用 `ReplAction` 式构造子 + 穷尽分发，漏 handler = 编译失败。trha 有语言优势未用——**结构性修复双表面漂移的根治法**。
2. **双表面切分要有语义**（opencode）：UI 类命令留 TUI 层；REPL 面要么共享实现、要么注册表加 `scSurfaces` 字段显式声明。trha 10 条占位应二选一。
3. **双目录是事故源**（Reasonix）：第二份清单必然漂移（3 条无执行器命令是实证）。trha 保持 Table.hs 单一来源，警惕 toolDeclarations(73) vs toolCatalog(74) 这类苗头。
4. **幽灵工具**（qwen save_memory）：常量在、实现无、权限残留引用。trha 无此问题，防复发靠 6.1 的编译期检查。
5. **审批进统一 pipeline**（dsh ToolExecutionPipeline / Reasonix executeOne）：把「权限→预演→执行→事件」收进一个管线对象，替代 executeTool 四级散布；顺带清掉 ~40 个迁移占位死分支（executor seam 是终态形态）。

## 7. 建议行动（按性价比）

| # | 动作 | 成本 | 收益 |
|---|---|---|---|
| 1 | 修 10 条 REPL 部分实现（共享 TUI 实现或加 `scSurfaces` 显式声明） | 中 | 用户可感知 |
| 2 | Table.hs 命令加编译期穷尽分发（学 haskell-agent ReplAction） | 小 | 结构性防漂移 |
| 3 | 删 ~40 个迁移空分支 + 补 `append_file` 声明行 + /mouse 入册 | 小 | 卫生 |
| 4 | tool-catalog.md 口径确认（74 正确）+ 溯源列（工具对齐 dsh 语义级、命令参考 MiMo/Reasonix/po 级别标注） | 小 | 溯源闭环 |

## 8. 证据与可复核性

七路审计均为源码直读（非文档转述），逐条带 file:line；trha 侧 91+107 条逐项普查表在审计会话记录中，关键路径已并入 §2。复核命令示例：

```bash
# 命令注册表条数
grep -c 'SlashCommand "' packages/app/CLI/UI/Commands/Registry/Table.hs   # → 91
# catalog 工具条数（多行 + 单行两种写法都要数）
grep -cE "^\s+name: '|name: '" packages/scheduler/src/Server/toolCatalog.ts  # → 74
# extraTools 名单
sed -n '58,68p' packages/scheduler/src/Server/extraTools.ts              # → 33 个
```
