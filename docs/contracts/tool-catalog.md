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
| `todo_write` | 整表替换会话待办（`pending/in_progress/completed`） | 会话（持久化 v2） |
| `create_goal` / `get_goal` / `update_goal` | 会话目标（objective/status/budget） | 会话（持久化 v2） |
| `schedule_create/list/update/delete` | 会话定时提示（记录 + 状态） | 会话（持久化 v2） |
| `job_list` / `job_output` / `job_kill` | 后台命令的列表/输出/终止 | 进程内（子进程不跨重启） |
| `skill` | 列出/加载 `TRHA_SKILLS_DIR`（默认 `<workspace>/.trha/skills`）下的 markdown | 文件系统 |
| `web_fetch` | 取 URL 文本（HTML 去标签/脚本，15s 超时，20k 字符上限） | – |

配置：`TRHA_WORKSPACE`（工作区，默认 `/tmp/trha-workspace`）、`TRHA_SKILLS_DIR`、
`TRHA_MAX_TOOL_ROUNDS`（0/未设 = 不限轮；同一调用连续重复 3 次判停）。

## 有意未移植（及原因）

| 工具 | 为什么不在 |
|---|---|
| `subagent` / `spawn_teammate` / `team_task_*` / `send_message` / `list_agents` / `interrupt_agent` / `workflow` | trha 没有多智能体运行时；只搬 schema 会变成模型能调、实际没人接的空壳 |
| `present` | 纯 UI 通道，要靠 shell 的渲染协议，不是 host 能力 |
| `ask_user_question` | 需要带自由文本的「回答」通道；现有审批闸门只有 yes/no，硬塞会把两种语义混成一个 |
| `exit_plan_mode` | 内核的多步计划/审批闸门已经覆盖这个语义，再加一个会变成两套并行的计划机制 |
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
