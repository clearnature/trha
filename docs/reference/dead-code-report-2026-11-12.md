# 死代码与账本漂移报告（命令/工具审计副产品，2026-11-12）

> **性质**：独立**报告**，不含处置动作。来源：七方对标审计（`commands-tools-cross-benchmark-2026-11-12.md` §2.3）+ trha 本地普查。
> **裁定背景**（用户，2026-11-12）：未实现命令走补全（见 `docs/plans/commands-completion-plan.md`）；死代码**先报告、不清理**，处置另行裁定。
> **复核方式**：每条附 grep/位置，均可 30 秒内复验。

## D1. 迁移占位空分支（最大宗，~130 行 × 3 处）

`scheduler` 工具执行从旧 if 链迁移到 `resolveTool` 注册表后，旧分支全部清空只剩注释，但代码留着：

| 位置 | 内容 | 规模 | 死因 |
|---|---|---|---|
| `packages/scheduler/src/Server/standardTools.ts:253-380` | 旧 `if (name === …)` 分支，每支只剩 "Migrated to the registry" 注释 | ~127 行 | `index.ts:1688 resolveTool` 永远先命中 |
| `packages/scheduler/src/Server/extraTools.ts:118-222` | 同上（33 个名字的空壳分支） | ~104 行 | 同上（`runExtraTool:101` 先走 resolveTool） |
| `packages/scheduler/src/Server/index.ts:1703-1735` | executeTool 内旧 if 链残留 | ~32 行 | 同上 |

死因确认方式：`resolveTool` 命中即 return（toolRegistry.ts:179 注册的 74 个执行体全覆盖 catalog 名单），这些分支不可达。

## D2. `/stop` 的 Meta.hs 死分支

`packages/app/CLI/UI/Commands/Meta.hs:54-55` 有 `/stop` 分支，但两个表面的主路径都先接管：REPL 在 `Main.hs:274`（stopAll）、TUI 在 `UI/Brick/Slash.hs:145-153`。该分支仅在异常路径可达，语义与主路径重复。

## D3. `/mouse` 隐藏命令未入册

`UI/Commands/Registry/Parser.hs:140` 有完整实现的 `/mouse`（→ `Config.hs:59 SetMouseCapture`），但不在 Table.hs 的 91 条 `slashRegistry` 中——帮助、picker、一致性 property（补全计划 T3）都看不见它。这不是死代码，是**实现完整但账外**，归类异常供裁定：入册（改 91→92）或保持隐藏但加注释说明。

## D4. `append_file` 缺 toolDeclarations 声明行

`packages/scheduler/src/Server/toolDeclarations.ts` 有 73 条声明（:39-138），`toolCatalog.ts` 有 74 个工具——差额正是 `append_file`（执行体在 standardTools.ts:1666，registerTool 自带 plane:'agent'，**执行不受影响**），缺的只是 preset 元数据声明。与 Reasonix 双目录漂移、qwen 幽灵工具同类的账本不一致苗头。

## D5. 非死代码但同源易混淆（备忘，不属处置范围）

- `bing` / `duckduckgo`（extraTools.ts:1208-1209）：web_search 的 HTML 后端标签，不是工具名——审计 grep 计数时的陷阱。
- toolCatalog「60 vs 74」口径：74 正确（60 多行 + 14 单行条目），旧对话与旧文档若出现 60/95/107 混用，以 74 + 33 extra 为准。

## 处置选项（供裁定，本报告不执行）

| 选项 | 内容 | 波及 |
|---|---|---|
| A. 全部清理 | 删 D1 三段空分支 + D2 死分支；D3 入册；D4 补声明行 | scheduler 三文件 + CLI 两文件；trha-cli-test / scheduler vitest 回归 |
| B. 只清 D1+D2，D3/D4 并入补全计划 | 死代码清零；账外项转正 | 同上略窄 |
| C. 冻结不处理 | 挂账，待工具注册表下一次改造（dsh 式 executor seam）时一并重构 | 零，但持续误导 grep 计数与新人 |
