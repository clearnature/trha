# CLI 命令对比矩阵（2026-11-03）

> 目的：回答「trha 的命令行到底缺什么」。
> 方法：直接读四个参考项目的命令定义源码，与 trha 的 `slashRegistry` 逐项对照。
> 结论先行：**trha 的命令数量不落后**（75 条，qwen-code 74 条、Reasonix 51 条），
> 落后的是**少数交互命令的接线**（回退、认证、插件重载）和**模板型命令**（init/review）。
> 2026-11-03 之前「完全不可使用」的直接原因是 `parseAnthropicTurn` 把
> `stop_reason` 当成 `ctError`，与命令覆盖无关（修复提交 `7761f95`）。

## 1. 数据来源

| 项目 | 版本/位置 | 命令定义来源 | 规模 |
| --- | --- | --- | --- |
| trha | `/home/yanli/work/trha` | `packages/app/CLI/UI/Commands/Registry.hs` `slashRegistry` | 75 |
| qwen-code | `/data/training/cli/qwen-code` | `packages/cli/src/ui/commands/*.ts`（每命令一文件） | 74 |
| MiMo-Code | `/data/training/cli/MiMo-Code` | `packages/cli/src/cli/cmd/tui/i18n/slash-command.ts` 的 `BUILTIN` + TUI 前缀命令 | 6 内置模板 + TUI 面 |
| DeepSeek-Reasonix | `/home/yanli/work/DeepSeek-Reasonix` | `internal/frontend/cli/slash_registry.go` `builtinSlashSpecs` | 51 |
| deepseek-harness (DSH) | `/home/yanli/work/deepseek-harness` | 插件注册：`packages/interaction/commands/src/index.ts` + `packages/*/command-*/src/index.ts` | 插件式（compact/feedback/goal + UI 层） |

## 2. 能力域矩阵

「—」表示该项目无此命令；空白表示 trha 已有等价命令。
trha 的命令名取自 `slashRegistry`，括号内是别名或参数提示。

### 2.1 会话

| 能力 | trha | qwen-code | MiMo | Reasonix |
| --- | --- | --- | --- | --- |
| 新建 | `/new` | `new` | — | `/new` |
| 列表 | `/sessions` | `list`/`sessions` | `open-sessions` | — |
| 恢复 | `/resume [n]` | `resume` | `select-session` | `/resume` |
| 重命名 | `/rename` | `rename` | `title` | `/rename` |
| 删除 | `/delete <id>` | `delete` | — | — |
| 分叉 | `/fork`、`/branch` | `fork`、`branch` | — | `/branch`、`/switch` |
| 树视图 | `/tree`、`/graph` | — | — | `/tree`、`/graph` |
| 导出 | `/export [json|md]` | `export` | — | `/export` |
| 历史 | — | `history` | `history` | — |
| **回退** | **缺** | `rewind` | — | `/rewind` |
| **快照恢复** | **缺** | `restore` | — | — |
| 摘要 | `/recap` | `summary`、`recap` | — | — |
| 会话详情 | `/session-info` | — | `session` | `/status` |

### 2.2 模型与 Provider

| 能力 | trha | qwen-code | MiMo | Reasonix |
| --- | --- | --- | --- | --- |
| 当前模型 | `/model [name]` | `model` | `models`、`open-models` | `/model` |
| 列模型 | `/models` | — | `models` | — |
| Provider | `/provider`、`/switch` | — | `provider`、`providers` | `/provider` |
| 预设 | `/preset` | — | — | `/preset` |
| 余额/用量 | `/usage` | — | — | — |
| 费率 | `/currency` | — | — | `/currency` |
| 代理 | — | — | `config` | — |
| **登录/密钥** | **缺** | `auth` | `auth` | — |

### 2.3 上下文与历史

| 能力 | trha | qwen-code | MiMo | Reasonix |
| --- | --- | --- | --- | --- |
| 上下文占用 | `/context` | `context` | — | `/context` |
| 压缩 | `/compact [focus]` | `compress`、`compress-fast` | — | `/compact` |
| 清空视图/历史 | `/cls`、`/clear` | `clear` | `clear-prompt` | `/cls`、`/clear` |
| 重放 | `/transcript` | `history` | `replay` | — |
| 统计 | `/stats` | `stats` | — | — |
| 附加文件 | `/attachments`、`/paste` | — | `append-prompt` | `/paste-image` |

### 2.4 工具、权限与沙箱

| 能力 | trha | qwen-code | MiMo | Reasonix |
| --- | --- | --- | --- | --- |
| 权限姿态 | `/mode` | `approval-mode` | `permission` | `/preset` |
| **规则查看** | **缺** | `permissions`、`trust` | `permission` | — |
| **工具清单** | **缺** | `tools` | `tool` | — |
| 沙箱 | `/sandbox` | — | — | `/sandbox` |
| MCP | `/mcp` | `mcp` | `mcp` | `/mcp` |
| LSP | `/lsp` | `lsp` | `lsp` | — |
| 技能 | `/skills` | `skills` | `skill` | `/skills` |
| 插件 | `/plugins` | `extensions`、`reload-plugins` | — | `/plugins`、`/reload` |
| 钩子 | `/hooks` | `hooks` | — | `/hooks` |
| 浏览器 | — | — | — | `/browser` |
| 联网 | — | — | — | `/web` |

### 2.5 输入与交互

| 能力 | trha | qwen-code | MiMo | Reasonix |
| --- | --- | --- | --- | --- |
| 外部编辑器 | `/vim` | `vim`、`editor` | — | — |
| 草稿暂存 | `/stash` | — | — | — |
| 复制 | `/copy` | `copy` | — | `/copy` |
| 排队/转向 | `/queue`、`/steer` | — | — | — |
| 旁问 | `/btw` | `btw` | `btw` | `/btw` |
| 循环执行 | `/loop` | — | — | — |
| 语音 | — | `voice` | — | — |
| **切换目录** | **缺** | `cd` | `project` | — |

### 2.6 计划与多 Agent

| 能力 | trha | qwen-code | MiMo | Reasonix |
| --- | --- | --- | --- | --- |
| 计划审批 | `/plan` `/approve` `/deny` `/skip` `/reject` `/abandon` | `plan` | — | — |
| 多 Agent | `/agents` | `agents`、`peers` | `agent` | `/agent` |
| 目标/TODO | `/goal`、`/todo` | `goal`、`tasks` | — | `/goal`、`/todo` |
| 工作流 | `/workflow` | `workflows` | `workflows` | — |
| 工作区 | `/workspace` | — | `worktree`、`path` | — |

### 2.7 维护与元信息

| 能力 | trha | qwen-code | MiMo | Reasonix |
| --- | --- | --- | --- | --- |
| 帮助 | `/help` | `help` | `open-help` | `/help` |
| 诊断 | `/doctor` | `doctor` | `health` | — |
| **关于/版本** | **缺** | `about` | — | — |
| **更新** | **缺** | `update` | `upgrade` | — |
| **反馈** | **缺** | `bug`、`feedback` | — | — |
| 文档 | — | `docs` | `doc` | `/docs` |
| 初始化项目 | **缺** | `init` | `init` | — |
| 记忆 | `/memory`、`/remember` | `memory`、`remember`、`forget` | — | `/memory`、`/remember`、`/forget` |
| 模板命令 | `/workflow` | `commands` | `command` | `/reload-cmd` |
| 迁移 | — | `import-config` | — | `/migrate` |
| 主题/外观 | `/theme`、`/output-style` | `theme`、`output-style`、`statusline` | `open-themes` | `/theme`、`/output-style` |
| 语言/时区 | `/language`、`/reasoning-language` | `language` | — | `/language`、`/reasoning-language` |

## 3. trha 缺失清单（按参考项目并集，去重、去等价项）

已排除等价项（`compress`≈`/compact`、`config`≈`/settings`、`approval-mode`≈`/mode`、
`tasks`≈`/todo`、`open-help`≈`/help`）。

| 缺口 | 来源 | 依赖 |
| --- | --- | --- |
| `/rewind` | qwen、Reasonix | 内核需支持截断到某一轮的 API |
| `/restore` | qwen | 文件快照/回滚（`~/.trha/file-history` 已有素材） |
| `/auth` | qwen、MiMo | provider key 管理（`provider-keys.json` 已存在） |
| `/update` | qwen、MiMo | 发布渠道与自更新脚本 |
| `/reload-plugins` | qwen、Reasonix | scheduler 插件热重载端点 |
| `/init` | qwen、MiMo | 模板 + 项目探测 |
| `/review` | MiMo | 模板 + diff 读取 |
| `/compress` | qwen | 可复用 `/compact` |
| `/cd` | qwen、MiMo | 会话工作目录切换 |
| `/tools` | qwen、MiMo | scheduler 工具注册表（已有 74 个） |
| `/permissions` | qwen、MiMo | 权限规则只读视图（`permissionRules.ts`） |
| `/history` | qwen、MiMo | 输入历史（`~/.trha/history` 已存在） |
| `/about` | qwen | 版本/构建信息 |
| `/summary` | qwen | 可复用 `/recap` |
| `/forget` | qwen、Reasonix | `~/.trha/memories` |
| `/docs` | qwen、Reasonix | 文档索引 |
| `/ide` | qwen | IDE 集成 |
| `/voice` | qwen | 语音输入 |
| `/trust` | qwen | 信任目录 |
| `/bug` | qwen | 问题模板/上报 |
| `/web` | Reasonix | 网页抓取 |
| `/browser` | Reasonix | 浏览器工具前缀 |
| `/migrate` | Reasonix | 配置迁移 |
| `/diff-fold` | Reasonix | TUI diff 折叠 |
| `/statusline` | qwen | 状态栏自定义 |
| `/terminal-setup` | qwen | 终端能力探测 |
| `/setup-github` | qwen | GitHub 认证 |
| `/arena` / `/advisor` / `/curator` / `/insight` / `/learn` / `/dream` / `/distill` / `/deep-research` / `/experimental` | qwen / MiMo | 实验性能力，暂不排期 |

## 4. 实施批次

按用户 2026-11-03 的裁定，四项目并集全做，按 C → B → A 顺序推进。

| 批次 | 命令 | 验收 |
| --- | --- | --- |
| **C 重交互** | `/rewind` `/restore` `/auth` `/update` `/reload-plugins` | 每条命令在 CLI 与 TUI 都能真实改变状态；内核契约变更登记到 `docs/contracts/` |
| **B 模板型** | `/init` `/review` `/compress` | 复用 `UI/CustomCommands.hs` 的 `$ARGUMENTS` 机制；模板可被用户覆盖 |
| **A 高频轻量** | `/cd` `/tools` `/permissions` `/history` `/about` `/summary` `/forget` | 不新增后端 API；纯读或写本地状态；每条带 spec |

### 4.1 C 批次的契约前置

| 命令 | 需要的后端能力 | 现状 |
| --- | --- | --- |
| `/rewind` | 截断会话到指定轮 | 无端点；`Core/Transcript` 可读、可写需新增 |
| `/restore` | 文件快照还原 | `~/.trha/file-history` 已有记录，无还原 API |
| `/auth` | key 写入/校验 | `provider-keys.json` 已存在，缺校验与写入路径 |
| `/update` | 版本检查与替换 | 无；需先定发布渠道 |
| `/reload-plugins` | scheduler 插件重载 | 无端点 |

### 4.2 B/A 批次的实现要点

- `/init`：写 `AGENTS.md` 骨架；模板放 `~/.trha/templates/init.txt`，可被项目覆盖。
- `/review`：读 `git diff` 交给模型评审；复用 `/diff` 的数据源。
- `/compress`：别名到 `/compact`，保留独立名字以对齐 qwen-code 习惯。
- `/cd`：切换会话工作目录（`/workspace` 已存在，`/cd` 是其 CLI 习惯名）。
- `/tools`：列 scheduler 注册的工具（74 个），按预设过滤。
- `/permissions`：只读展示 `deny > ask > allow` 规则。
- `/history`：读写 `~/.trha/history`。
- `/about`：版本、构建时间、内核/调度器 PID。
- `/summary`：别名到 `/recap`。
- `/forget`：删除匹配的 `~/.trha/memories` 条目。

## 5. 不在本矩阵范围内

- TUI 交互形态（多行输入、审批浮层、diff 渲染）已在
  `docs/plans/tui-port-plan.md`（M0–M10）跟踪，本文不重复。
- 工具本身的能力（74 个 scheduler 工具）不在命令层评估。
