# 74 个工具的网关实测

两段：**网关扫描**（脚本模型，逐工具走同一个 HTTP 入口）与**真模型运行**（DeepSeek，看它自己怎么挑）。

## 1. 网关扫描（脚本模型）

入口与外壳完全一致：`POST /api/agent/step` → `runStep` → `executeTool`。
夹具都是真的：本地 HTTP 页、假 MCP 服务（stdio JSON-RPC）、假 LSP（Content-Length 帧）、
git 仓库、`package.json`、技能目录。有状态工具按组在同一会话里顺序执行
（goal、team task、schedule、terminal、job、session events）。

判定口径：
- `ok`：工具真的做了事（文件落盘、命令输出、浏览器渲染、子会话跑起来…）
- `refused`：按文档拒绝（未知 id、未配置、二进制缺失）——是**正确行为**
- `error` / `unwired` / `threw`：缺陷


Tools: 74 · rows: 56 · verdicts: {"ok":50,"refused":6}

| tool / sequence | verdict | detail |
|---|---|---|
| `create_goal → get_goal → update_goal` | ok | OK: goal updated {"objective":"sweep","status":"complete","createdAt":"2026-10-24T03:34:19.626Z"} (95ms) |
| `todo_write → team_task_create → team_task_list → team_task_update → team_task_get` | ok | {"id":"t1","subject":"sweep task","status":"completed"} (37ms) |
| `schedule_create → schedule_list → schedule_update → schedule_delete` | ok | OK: deleted sch-1 (27ms) |
| `terminal_open → terminal_send → terminal_read → terminal_list → terminal_close` | ok | OK: closed term-1 (36ms) |
| `subagent → list_agents` | ok | session-1792812859583 idle 8 msgs session-1792812859646 idle 12 msgs session-1792812859683 idle 10 msgs sessio (17ms) |
| `bash → job_list → job_output → job_kill` | ok | OK: killed job-1 (25ms) |
| `session_event_read → session_event_search → session_event_trace` | ok | (no kernel events; kernel unreachable or session unknown) (35ms) |
| `read` | ok | 1 alpha 2 beta (11ms) |
| `write` | ok | OK: write -> /tmp/trha-sweep-w6FWRK/ws/w.txt (7 chars) (12ms) |
| `edit` | ok | OK: edit -> /tmp/trha-sweep-w6FWRK/ws/notes.txt (1 replacement) (14ms) |
| `glob` | ok | notes.txt w.txt (11ms) |
| `grep` | ok | notes.txt:1:alpha (10ms) |
| `send_message` | refused | ERROR: no agent x (12ms) |
| `interrupt_agent` | ok | OK: x was idle (11ms) |
| `workflow` | ok | [ { "name": "a", "agent": "session-1792812859904#a-2", "reply": "(no tool result)" } ] (13ms) |
| `list_mcp_resources` | ok | file:///n.txt n  (61ms) |
| `list_mcp_resource_templates` | ok | file:///{p} t (12ms) |
| `read_mcp_resource` | ok | mcp text (15ms) |
| `lsp` | ok | hover! (66ms) |
| `browser_navigate` | ok | title: Sweep url: http://127.0.0.1:32809/ hello page Go (791ms) |
| `browser_extract` | ok | hello page (18ms) |
| `browser_screenshot` | ok | OK: screenshot -> /tmp/trha-sweep-w6FWRK/ws/shot.png (84ms) |
| `browser_close` | ok | OK: browser closed (13ms) |
| `ask_user_question` | ok | pick one (9ms) |
| `exit_plan_mode` | ok | do the sweep (15ms) |
| `present` | ok | PRESENT: {"title":"Sweep","body":"done"} (12ms) |
| `run_code` | ok | exit 0 code-ok  (59ms) |
| `read_image` | ok | data:image/png;base64,iVBORwAAAAA= (14ms) |
| `skill` | ok | # demo skill (17ms) |
| `web_fetch` | ok | HTTP 200 text/html Sweep hello page Go (17ms) |
| `working_directory` | ok | OK: cwd is now /tmp/trha-sweep-w6FWRK/ws/sub (12ms) |
| `str_replace_editor` | ok | 1 alpha 2 BETA 3  (11ms) |
| `unified_edit` | ok | 1 alpha 2 BETA 3  (11ms) |
| `terminal_signal` | refused | ERROR: no terminal term-1 (12ms) |
| `wait_agent` | refused | ERROR: no agent x (11ms) |
| `spawn_teammate` | ok | teammate session-1792812861179#mate-3 finished: (no tool result) (14ms) |
| `session_search` | ok | session-1792812859583 #2 tool OK: goal created {"objective":"sweep","status":"active","createdAt":"2026-10-24T (12ms) |
| `session_trace` | ok | #0 user run:session_trace #1 assistant  (14ms) |
| `create_worktree` | ok | OK: worktree at wt on sweep-branch 准备工作区（新分支 'sweep-branch'） HEAD 现在位于 f7671d1 init  (156ms) |
| `load_workspace_dependencies` | ok | $ npm install exit 0 up to date, audited 1 package in 348ms found 0 vulnerabilities  (607ms) |
| `pwsh` | refused | ERROR: pwsh is not installed (spawn pwsh ENOENT) (24ms) |
| `web_search` | ok | Searched https://example.com found it (21ms) |
| `list_subagent_models` | ok | deepseek-flash DeepSeek-V4.1-Flash deepseek-v4-pro DeepSeek-V4-Pro (17ms) |
| `plugin_manager` | ok | (no plugins) (16ms) |
| `cordis_inspect_list` | ok | (no plugins) (14ms) |
| `cordis_inspect_query` | refused | ERROR: no plugin nope (13ms) |
| `plugin_market` | refused | ERROR: plugin_market needs TRHA_PLUGIN_MARKET (URL or JSON file) (14ms) |
| `stagehand_navigate` | ok | title: Sweep url: http://127.0.0.1:32809/ hello page Go (779ms) |
| `stagehand_extract` | ok | hello page (14ms) |
| `stagehand_screenshot` | ok | OK: screenshot -> /tmp/trha-sweep-w6FWRK/ws/sh2.png (58ms) |
| `stagehand_tabs` | ok | single-tab mode; current url: http://127.0.0.1:32809/ title: Sweep (22ms) |
| `stagehand_observe` | ok | Go (20ms) |
| `stagehand_act` | ok | clicked (17ms) |
| `ralph` | ok | round 1 (session-1792812863011#ralph-1-4): (no tool result) (18ms) |
| `append_file` | ok | OK: append_file -> /tmp/trha-sweep-w6FWRK/ws/w.txt (5 chars) (13ms) |
| `bash(background) → job_output` | ok | OK: started job-1 (use job_output to read it) (30ms) |

**结论：50 ok / 6 refused / 0 error / 0 unwired / 0 threw。**
6 个 refused 全是文档化的正确拒绝：未知 agent/job/schedule id、`pwsh` 未安装、
`plugin_market` 未配置、插件名不存在。

## 2. 真模型运行（deepseek-flash，reasoning_effort=low）

任务：todo_write 建三条待办 → run_code 算 `sum(range(10))` → present 一张卡 → 汇报。

模型实际调用 **5 次**：`todo_write`（建）→ `run_code`（45）→ `todo_write`（标记完成）
→ `present`（卡片）→ `todo_write`（收尾），最终汇报准确（45，退出码 0）。

用量：prompt 21192 / completion 790，缓存命中 **96.04%**（20352 hit / 840 miss）。

### 这轮真机跑出来的三个 bug（已修）

1. **并行 tool_calls 被合并**：内核转发时把 `index` 恒写成 0、丢了 `id`，
   两个调用变成 `todo_writerun_code` + 空 id → 模型看到坏历史后开始重复调用，
   触发「重复调用」保护。修法：`ChunkToolCallAt` 带上 index 与 provider id，
   SSE 原样透传（`index` + `id` + `type`）。
2. **`present` 把卡片 assistant 消息插在 tool_calls 与 tool 结果之间**，
   历史结构非法 → provider 400「insufficient tool messages」。修法：先落工具结果，
   再把卡片作为 UI 状态（`session.presentations`）记录，不进模型历史。
3. **thinking 模式要求每条 assistant 消息带 `reasoning_content`**：
   `present` 造出的合成 assistant 消息没带 → 400。修法：DeepSeek 请求构造时给
   缺少该字段的 assistant 消息补 `""`（只补缺失，不伪造内容），同时把 UI 消息
   移出历史。

顺带：`WAITING_FOR_INPUT/APPROVAL` 现在也先把工具结果写进历史再结束本轮，
否则下一次请求同样会因「tool_calls 未应答」被拒。

## 3. 让模型别反复写 todo（同一任务复测）

发现 `mode.persona` 是**死配置**——`runStep` 从来没发过 system 消息，模型收到的
第一条就是 user。于是把 persona 真正渲染成 system message（每次请求计算，不落盘、
不污染 transcript），并在其中加入工具纪律：

> `todo_write` 替换整份清单：建计划时写一次，整批完成后最多再写一次；
> 单个动作之间不要重写；清单没变就别调用。独立工具调用合并到一轮。

同一任务复测（deepseek-flash）：

| | 修复前 | 修复后 |
|---|---|---|
| 工具调用 | 5 次（todo_write ×3，逐个发） | 4 次（todo_write ×2，首轮并行 todo/run_code/present） |
| 汇报准确性 | 45 ✅ | 45 ✅ |

system 消息现在带 `working directory is <cwd>`，`{{cwd}}`/`{{model}}` 会被替换；
`minimal` 等 `persona.enabled=false` 的模式仍然不发 system 消息（有测试钉住）。

### 再进一步：服务端兜住幂等

提示只能劝，服务端要拦住：`todo_write` 现在会与当前清单做**顺序无关**的比较，
完全相同就返回 `UNCHANGED: N todos (the list is identical; nothing was written)`，
**不写状态、不落盘**；工具描述也改成「只有清单真的变了才调用，相同重写会被拒为
UNCHANGED」。真机同一任务复测保持 4 次调用（todo_write 2 次），其中若出现
相同重写会被这条规则吃掉。

