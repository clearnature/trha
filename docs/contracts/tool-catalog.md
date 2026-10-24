# 工具目录（对齐 deepseek-harness standard preset）

共 **74** 个工具，覆盖 dsh `standard` 预设的全部名字。模型可见的工具集由
`packages/scheduler/src/Server/toolCatalog.ts` 单一来源定义，
执行器按同一份名字分派；旧名通过 `TOOL_ALIASES` 映射，不会与目录漂移。

## 已实现

| 工具 | 语义 | 落盘/生命周期 |
|---|---|---|
| `bash` | 在工作区跑 shell；`background: true` 转后台 job | 进程内 |
| `read` | 读文件，支持 `offset`/`limit`，返回行号 | – |
| `write` | 写文件（自动建父目录，覆盖） | 工作区 |
| `edit` | 精确串替换，要求唯一匹配（`replace_all` 可放宽） | 工作区 |
| `glob` | 按 glob 列文件（跳过 node_modules/.git/dist/.lake/target） | – |
| `grep` | 正则搜内容，返回 `path:line:text`，可带 `glob` 过滤 | – |
| `append_file` | 追加写 | 工作区 |
| `ask_user_question` | 向用户提问并**结束本轮**，答案经 `POST /api/session/:id/answer` 回来 | 会话（持久化 v2） |
| `exit_plan_mode` | 请求批准进入执行；复用内核审批闸门（不另造计划机制） | 会话 |
| `present` | 展示一张卡（title+body），不结束本轮 | 会话 |
| `run_code` | 跑片段（python/javascript/bash/lean），返回退出码与输出（20k 上限） | 工作区临时文件 |
| `read_image` | 图片转 data URL 供视觉模型，2 MiB 上限 | – |
| `todo_write` | 整表替换会话待办（`pending/in_progress/completed`） | 会话（持久化 v2） |
| `create_goal` / `get_goal` / `update_goal` | 会话目标（objective/status/budget） | 会话（持久化 v2） |
| `schedule_create/list/update/delete` | 会话定时提示；**到点自动触发一轮**（`repeat_ms` 可重复） | 会话（持久化 v2）+ 驱动 |
| `job_list` / `job_output` / `job_kill` | 后台命令的列表/输出/终止 | 进程内（子进程不跨重启） |
| `skill` | 列出/加载 `TRHA_SKILLS_DIR`（默认 `<workspace>/.trha/skills`）下的 markdown | 文件系统 |
| `web_fetch` | 取 URL 文本（HTML 去标签/脚本，15s 超时，20k 字符上限） | – |
| `subagent` | 起一个**子会话**跑任务并返回最终答复（真实 `runStep`，非拼接文本） | 子会话（持久化） |
| `list_agents` | 列出会话：id、busy/idle、消息数、父会话 | – |
| `send_message` | 给另一个会话发消息；空闲则立刻跑一轮，忙碌则排队 | – |
| `interrupt_agent` | 让某个会话在**轮次边界**停下（下一轮开头检查） | – |
| `team_task_create/list/update` | 共享任务表，挂在**根会话**上，子会话也看得到 | 会话（持久化 v2） |
| `workflow` | 按顺序跑 `[{name, task}]`，逐个起子智能体并汇总结果 | 子会话 |
| `list_mcp_resources` / `list_mcp_resource_templates` / `read_mcp_resource` | MCP 资源三件套（stdio JSON-RPC 客户端） | `TRHA_MCP_CONFIG` |
| `lsp` | 语言服务器查询：hover / definition / references / diagnostics / symbols | `TRHA_LSP_COMMAND` |
| `browser_navigate` / `browser_extract` / `browser_screenshot` / `browser_close` | 真 headless Chrome（CDP），**每个会话一个标签页**（`Target.createTarget` + 按 CDP sessionId 分流）：渲染后取文本、取选择器、截图 PNG；`browser_close` 只关本会话的页 | `TRHA_BROWSER` |
| `working_directory` | 读/切会话 cwd（必须留在工作区内）；bash 与 fs 工具都跟随 | 会话（持久化 v2） |
| `str_replace_editor` / `unified_edit` | 编辑器式操作：view / create / str_replace / insert | 工作区 |
| `terminal_open/send/read/signal/close/list` | 每会话持久 shell：输入、增量读、发信号、关闭 | 进程内 |
| `wait_agent` | 等某会话空闲（有上限）；`spawn_teammate` 起具名队友并登记任务 | – |
| `team_task_get` | 读一条团队任务 | 会话 |
| `session_search` / `session_trace` | 跨会话搜消息 / 单会话时间线 | 会话存储 |
| `session_event_read/search/trace` | 内核事件日志：尾部读取 / 子串搜索 / 按 kind 计数 | 内核 `/session/:id/events` |
| `create_worktree` | `git worktree add` 新分支 | 仓库 |
| `load_workspace_dependencies` | 按清单装依赖（pnpm/npm/cargo/stack/cabal） | 工作区 |
| `pwsh` | PowerShell 命令（无 pwsh 时明确报错） | – |
| `web_search` | 搜索（SearXNG JSON 优先，否则 DuckDuckGo HTML） | `TRHA_SEARX_URL` |
| `list_subagent_models` | 列出可供子智能体使用的模型 | – |
| `plugin_manager` / `cordis_inspect_list` / `cordis_inspect_query` | 列出/检视已加载插件与其钩子 | – |
| `plugin_market` | 插件市场列表（URL 或 JSON 文件） | `TRHA_PLUGIN_MARKET` |
| `stagehand_navigate/extract/screenshot/tabs/act/observe` | stagehand 语义的别名 + `act`（click/type）与 `observe`（交互动元素） | 共用 CDP 浏览器 |
| `ralph` | Ralph 循环：每轮**全新子会话**，共享工作区，直到 DONE/BLOCKED | 子会话 |

配置：`TRHA_WORKSPACE`（工作区，默认 `/tmp/trha-workspace`）、`TRHA_SKILLS_DIR`、
`TRHA_MAX_TOOL_ROUNDS`（0/未设 = 不限轮；同一调用连续重复 3 次判停）、
`TRHA_SCHEDULE_TICK_MS`（驱动轮询，默认 5000，0 = 关闭）、
`TRHA_SCHEDULE_GRACE_MS`（重启补跑窗口，默认 5 分钟）。

## 调度驱动（schedule → 真实回合）

记录只是半个功能，另一半是把 `at` 变成一次回合。驱动在 scheduler 内按 tick 轮询：

- **触发**：`at <= now` 且 `status=active` → 先用**同一条** `runStep` 跑（和 HTTP 路由一样），
  再把 `runs+1`、`lastFiredAt` 落盘；一次性任务置 `fired`，`repeat_ms` 任务把 `at` 推到下一次。
- **先落盘再花钱**：`runs/at` 在调用模型前写入，崩溃不会导致同一时刻重复触发。
- **屏障**：`pendingApproval` 存在时不触发（宿主还欠一个决策）。
- **重启补跑**：宕机期间到期的任务，若在 grace 窗口内则补触发；超出的标记 `missed`
  —— 把任意积压一次性重放会变成账单炸弹，静静丢弃又会让任务假装被遵守。
- **生命周期**：`createServer` 返回 `stop()`，关闭时清定时器（否则「关了」的进程还在花钱）。
- **可观测**：每次触发发 `agent:schedule` SSE（`firing` / `done` / `error`）。

## 配置

| 变量 | 作用 | 默认 |
|---|---|---|
| `TRHA_WORKSPACE` | 工具工作区（读写边界） | `/tmp/trha-workspace` |
| `TRHA_SKILLS_DIR` | `skill` 的 markdown 目录 | `<workspace>/.trha/skills` |
| `TRHA_MAX_TOOL_ROUNDS` | 工具轮上限 | 不限（同一调用连续重复 3 次判停） |
| `TRHA_MAX_SUBAGENT_DEPTH` | 子智能体嵌套深度 | 2 |
| `TRHA_SCHEDULE_TICK_MS` / `TRHA_SCHEDULE_GRACE_MS` | 调度轮询 / 重启补跑窗口 | 5000 / 5min |
| `TRHA_MCP_CONFIG` | MCP 服务器配置 JSON | 未设＝未配置 |
| `TRHA_LSP_COMMAND` / `TRHA_LSP_ROOT` | 语言服务器命令 / 根目录 | `typescript-language-server --stdio` / workspace |
| `TRHA_BROWSER` | 浏览器可执行文件 | `chromium` |
| `TRHA_SEARX_URL` | `web_search` 的 SearXNG 地址 | 未设＝DuckDuckGo HTML |
| `TRHA_PLUGIN_MARKET` | 插件市场 URL 或 JSON 文件 | 未设＝报错说明 |

## 为什么没有直接 `npm i` dsh 的工具包

dsh 的工具是**已发布**的（`@deepseek-ai/dsh-tool-*`，`next=0.2.1-rc.3`），但它们是
cordis 插件，不是独立函数。实测（临时目录，未改仓库）：

```js
import { Context } from '@deepseek-ai/cordis'
ctx.plugin(dshFs); ctx.plugin(dshTools); ctx.plugin(dshToolFs)
// tool-fs 的 inject = ['tools','fs','systemPrompt','workingDirectory']
ctx.tools.get('read').execute(args, exec)   // exec: ToolExecution —— 要有 agent/session/scope/approval
```

也就是说，直接复用它们需要**把 dsh 的 agent 运行时作为 sidecar 嵌进来**（cordis +
`dsh-agent`/`dsh-session`/`dsh-sandbox`/`dsh-user-approval` 一整条服务链），
而不是「拷几个文件」。那是一次架构集成，不是一次移植。

因此这四类（多智能体、MCP、LSP、浏览器）是按 dsh 的**语义与 schema** 在我们自己的
host 上实现的：子智能体复用本进程的 `runStep`，MCP 是 stdio JSON-RPC 客户端，
LSP 是 Content-Length 帧客户端，浏览器是 CDP。工具面已与 dsh `standard` 预设对齐；
差别在于**运行时**是 trha 的，而不是嵌入 dsh 的 agent。
