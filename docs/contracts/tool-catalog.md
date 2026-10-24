# 工具目录（对齐 deepseek-harness standard preset）

模型可见的工具集由 `packages/scheduler/src/Server/toolCatalog.ts` 单一来源定义，
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

## 有意未移植（及原因）

| 工具 | 为什么不在 |
|---|---|
| `subagent` / `spawn_teammate` / `team_task_*` / `send_message` / `interrupt_agent` / `list_agents` / `workflow` | 见下节「为什么没有直接装 dsh 的包」 |
| `pwsh` | Windows 专用（本机 Linux） |
| `lsp` / `read_image` / `stagehand_*` / `read_mcp_resource` | 依赖 LSP 客户端、视觉模型桥、浏览器、MCP 连接，属于外部集成 |
| `run_code` | 与 `bash` 重叠，且需要多语言运行时池 |

判断标准：**模型能调、宿主真能执行、结果真能回读**。缺其中任何一条，就不放进目录 ——
否则工具调用会退化成「看起来在工作」的表演。

## 测试

`packages/scheduler/test/`：

- `tools-fs.test.ts` —— write/edit/read 区间/grep/glob 全链，歧义 edit 拒绝，重复调用判停
- `standard-tools.test.ts` —— todo/goal/schedule/job/skill/web_fetch 各一组，
  以及「同 session id 跨 scheduler 重启后 goal 仍在」
- `tool-catalog.test.ts` —— 目录顺序、必填字段、旧名别名

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

当前选择：按 dsh 的**语义与 schema** 在我们自己的 host 上实现（上表），
只在做不到的地方（MCP/LSP/浏览器/多智能体）保留缺口并写清原因。
如果要把剩余部分也吃下来，正确做法是接入 dsh 运行时——这需要单独立项。
