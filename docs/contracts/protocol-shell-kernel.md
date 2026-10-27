# trha 外壳↔编排层 共享协议总账（Phase 3 三端基线）

**日期**: 2026-09-05（北京时间）
**层**: 外壳（CLI/TUI/桌面/Web） ↔ TS 编排层（packages/scheduler，默认 `https://127.0.0.1:28433`，Bearer token）
**文档依据**: 已实现代码（S0-S2）——任何新增端按此契约接入；任何改动须同步本表与对应契约测试。

---

## 1. 传输与认证
- **默认 HTTPS**（TLS 1.2+）：scheduler 启动时启用 TLS；证书来源优先 `TRHA_TLS_CERT` + `TRHA_TLS_KEY`，
  否则在 `~/.trha/tls/{cert.pem,key.pem}` 生成自签证书（SAN `127.0.0.1`/`localhost`，key 0600）。
  `TRHA_TLS=0|false|off` 关闭 TLS，退回纯 HTTP。
- HTTP/1.1 JSON（Content-Type: application/json）+ SSE（text/event-stream）长连
- 认证：`Authorization: Bearer <token>`（缺省 `dev-token`/env `TRHA_TOKEN`）；`/health` 与 `/v1/*` 豁免
- 错误形态：`{"error": "..."}` + 非 2xx（401/404/400/500）
- 外壳侧协议由 `configScheme`（`https` 默认 / `http`）决定；回环目标使用自签证书（CLI 对 127.0.0.1/localhost 跳过证书校验，
  远程目标仍走系统信任库）。`GET /` 302 到 `/studio/`（浏览器入口）。

### 1.1 运行文件与停止（2026-10-27）

| 文件 | 写入者 | 内容 |
|---|---|---|
| `~/.trha/run/kernel.pid` | `trha serve` | 内核 pid（0700 目录，文件 0600） |
| `~/.trha/run/scheduler.pid` | scheduler `cli.ts` | scheduler pid |

- `trha status`：只读报告两个服务的 pid 与存活状态。
- `trha stop [kernel|scheduler|all] [--force]`：**只**向 pid 文件记录的进程发 SIGTERM；
  5 秒未退出则报错（非零退出），`--force` 才升级为 SIGKILL。
- **身份校验**：停止前读 `/proc/<pid>/cmdline`，不匹配（pid 复用）则拒绝，绝不误杀。
- **不做**进程名匹配（`pkill`）或按端口杀。
- 启动时若 pid 文件指向存活的同类进程，拒绝启动并提示先 `trha stop <service>`。
- 外壳侧：`/quit`、Ctrl+Q、Desktop 关窗都只退出当前壳；TUI `/stop` 需 `/stop confirm`；
  Desktop 用 `Services → Stop kernel and scheduler…`（Ctrl+Shift+Q）+ 原生确认框；
  两者最终都走同一套 pid 文件 + SIGTERM 逻辑（终端版是 `trha stop`）。
- scheduler 启动时写 `~/.trha/run/scheduler.token`（0600）；复用外部 scheduler 的外壳
  （Desktop）读它认证，而不是自带随机 token。
- **单一发现文件 `~/.trha/runtime.json`（2026-10-27）**（0600，原子替换）：

  ```json
  {
    "kernel":    { "host": "127.0.0.1", "port": 19433, "pid": 1234, "token": "<per-launch>" },
    "scheduler": { "host": "127.0.0.1", "port": 28433, "pid": 5678, "token": "<dev-token>" }
  }
  ```

  - 内核 `startServer` 写 `kernel` 段（退出时 `finally` 删除自己的段，仅当 pid 匹配）；
  - scheduler `cli.ts` 写 `scheduler` 段（进程退出时删除）；
  - 外壳读它发现**活端口/token**：CLI `createSchedulerBridge` 在端口仍是默认值（28433）时采用；
    Desktop `resolveSchedulerToken` 优先读它，回退旧的 `~/.trha/run/scheduler.token`。
  - 旧的 `kernel-token` / `scheduler.token` 文件仍保留（兼容旧版本），新代码以 `runtime.json` 为准。

### 1.2 壳级键位 vs 服务级命令（2026-10-27）

| 层 | 键 / 命令 | 语义 |
|---|---|---|
| 壳 | `Ctrl+Q` | 退出当前壳 |
| 壳 | `Ctrl+C` | 运行中 → 中断；输入非空 → 清空；空闲且空 → 3 秒内再按一次退出 |
| 壳 | `Ctrl+D` | 空闲且输入为空 → 退出 |
| 壳 | `/quit`、`/exit` | 退出当前壳 |
| 服务 | TUI `/stop` → `/stop confirm` | 停内核 + scheduler，并退出 TUI |
| 服务 | Desktop `Ctrl+Shift+Q` | 确认框 → 停内核 + scheduler |
| 服务 | `trha stop` | 终端版，同上 |

- 键事件**不跨进程**（未注册 `globalShortcut`）；`quit` 只影响自己的壳。
- `stop` 的作用对象是**共享后端**：任一入口 stop，其他入口立即断连。
- `Ctrl+Q` 沿用旧习惯保留；终端流控（XON）可能吞掉它，因此 `Ctrl+C` 两次与 `Ctrl+D` 是替代出口。

## 2. 端点清单
| 方法/路径 | 请求 | 成功响应 | 契约测试 |
|---|---|---|---|
| GET /health | – | `{status:"ok",version,modes[]}` | CLI Bridge healthCheck |
| POST /api/session/start | `{mode}` | `{sessionId, mode}` | vitest index |
| GET /api/sessions | – | `[{id,mode,messages[],createdAt}]` | CLI listSessions |
| GET /api/session/:id | – | session 对象 | – |
| GET /api/session/:id/messages | – | `{messages:[{role,content}]}` | CLI getMessages |
| DELETE /api/session/:id | – | `{ok,sessionId}` | CLI deleteSession |
| POST /api/agent/step | `{sessionId,message,requireApproval?}` | `{reply,messages,mode}` 或 `{status:"awaiting_approval",pending:{message},mode}` | vitest; CLI sendMessage/planStep |
| POST /api/session/:id/decision | `{approve:bool}` | `{status:"approved",reply,…}` 或 `{status:"denied",mode}`；无挂起→400 | vitest S1; CLI approve/denyPlan |
| POST /api/session/:id/interrupt | `{}` | `{aborted:bool}`；空闲会话返回 `false` 且不置标志 | vitest interrupt; CLI interruptSession |
| GET /api/session/:id/mode | – | `{mode,label,planMode,yoloRestore,cycle[]}` | vitest permission-modes |
| POST /api/session/:id/mode | `{action:"cycle"|"yolo"|"set", mode?}` | 同上（服务端裁决后的姿态） | vitest permission-modes |
| GET /api/models | – | `[{name,description,contextSize}]` | CLI listModels |
| GET /api/plugins | – | `[{name,version,description}]`（运行时已注册插件） | vitest plugins-runtime |
| POST /api/plugins | `{name,version,description}`（宣告型，无钩子） | 201 `{ok,name}`；重复 409 | vitest plugins-dynamic |
| DELETE /api/plugins/:name | – | 200 `{ok,name}`；不存在 404 | vitest plugins-dynamic |
| GET /api/events/:sessionId | –(SSE) | data 帧（见 §3） | vitest tool-events |
| GET /v1/models · /v1/chat/completions(±stream) · /v1/messages(±stream) · /v1/responses(±stream) | OpenAI/Anthropic/Responses | 标准协议 | vitest protocols |

> **多步计划的端点**（同为转发）：`POST/GET /api/session/:id/plan`、
> `POST /api/session/:id/step-result`，以及 `POST /api/session/:id/decision`
> 带 `{action: "approve"|"skip"|"reject"|"abandon"}` 时走计划分支（不带 `action`
> 仍是原单命令闸门的 `{approve:bool}`）。响应体在内核返回之上补 `mode`。
>
> **审批闸门的事实源在内核**：`requireApproval` 与 `decision` 两个路由会把请求
> 转给内核 `/session/:id/approval` 与 `/session/:id/decision`（内核持有
> `awaiting_approval` 状态、做屏障、并落盘跨重启）。内核不可达时编排层降级为本地
> `pendingApproval`，上表响应形状不变。详见 `docs/architecture/architecture.md` §3.3。
>
> **中断语义**：`interrupt` 置会话的 `abortRequested`，工具循环在**轮次之间**检查并
> 以 `(interrupted)` 收尾；因此它只能停在下一轮边界，不能打断正在进行的单次模型
> 生成。空闲会话拒绝置标志（否则会中止下一轮），且每轮结束（`finally`）都会清标志，
> 迟到的中断不会泄漏到后续轮次。三个外壳共用该语义。

## 3. SSE 事件帧（data: JSON，按 sessionId 过滤）
| event 语义 | 载荷（字段） | CLI 类型 |
|---|---|---|
| 消息 | `{sessionId,role:"user"\|"assistant",content}` | –（回放/日志用） |
| 思考增量 | `{sessionId,reasoning}`（`agent:reasoning`，流式时逐段） | 累积到 thinking 卡；不进 transcript |
| 轮次边界 | `{sessionId,round,messageCount,toolCount}`（`agent:model-request`） | step 分隔行 |
| 上下文压缩 | `{sessionId,trigger,savedTokens,prefixChanged:true}`（`agent:context`） | compaction 卡 |
| 重试 | `{sessionId,attempt,delayMs,reason}`（`agent:retry`） | retry 行 |
| 计划挂起 | `{sessionId,status:"awaiting_approval",message}` | PlanSubmit |
| 决策 | `{sessionId,approve:bool}` | PlanVerdict |
| 工具生命周期 | `{sessionId,name,args?,status:"running"\|"succeeded"\|"failed",error?,durationMs?,output?}`（`output` 仅 succeeded 携带，内核尾部预览：末 12 行 ≤2KiB，供 TUI 工具卡展开态；可选字段，旧外壳忽略） | ToolEvent（Core.Types From/ToJSON roundtrip 测试） |

### 3.1 权限姿态（Shift+Tab / Ctrl+Y，2026-10-25）

会话级状态，服务端持有（`/api/session/:id/mode`），两个外壳共用同一裁决：

- **五态循环**（Shift+Tab）：`read-only → ask → auto → YOLO → plan → read-only`。
- **Ctrl+Y**：YOLO ↔ 切换前的姿态（`ask`/`auto`/`read-only`）；在 `plan` 下只切 YOLO，
  `planMode` 不变（计划不因快捷键被打断）。
- **裁决顺序**：显式 `deny` 规则**永远优先**；其后按姿态：
  `read-only`/`plan` 只放行只读工具（`Permission/modes.ts` 白名单），
  `ask` 对非只读工具要求确认，`auto` 走原 deny>ask>allow 规则，`YOLO` 跳过 ask 规则。
- **状态栏**：`Mode: <label>` · `cache 本次命中 X% · 平均 Y%` ·
  `context <used> (<pct>%)` · `compact <80-pct>%`。缓存率只在 provider 真的报了
  `cacheHitTokens/cacheMissTokens` 时显示（不编 0.00%）。

> 本地外壳键位：vty `KBackTab`（`Shift+Tab` 的 CSI-Z 编码）与 `KChar '\t' + MShift`
> 都接；`Ctrl+Y` 为 `KChar 'y' + MCtrl`。

## 4. 本地外壳数据（~/.trha）

目录骨架由 `Config.Home.homeLayout` 定义，**由 `trha setup` 创建**，权限一律 0700
（与参考 CLI 的 `~/.claude`、`~/.codex`、`~/.dsh`、`~/.reasonix` 同级结构对齐）。
`trha setup` 是交互式向导：目录 → 界面语言 → 主题 → 思考语言 → provider/model → API key，
结束时做一次本地自检（目录权限 / settings.yaml / provider+key / git）；
`--yes`（或 stdin 非终端）只建骨架、保留现有配置。
普通启动只保证 `~/.trha` 与 `settings.yaml`；各命令写自己需要的目录时按需创建。
松散文件保持在根目录，不放子目录。

| 项 | 说明 |
|---|---|
| settings.yaml（0600，分层：CLI args > ./项目 > ~/ 用户 > 默认） | host/port/model/token/maxTokens/timeout/retries/verbose/theme/lang/reasoningLanguage |
| providers.json · provider-keys.json（0600） | 供应商清单与密钥 |
| history · frecency.json · models.json · currency.json · stash.jsonl | 小状态文件，**新写入 `state/`**；旧位置的同名文件仍会被读取（不自动删除） |
| state/ | `history`、`frecency.json`、`models.json`、`currency.json`、`stash.jsonl` |
| sessions/<sid>/transcript.jsonl | jsonl 事件：session/user/assistant/tool(+status,error,durationMs)/done/error（向后兼容扩展字段） |
| scheduler-state/ | scheduler 持久化的会话状态（`TRHA_STATE_DIR` 未设时的默认目录） |
| skills/ | `<name>/SKILL.md`，由 `/skills` 扫描（也扫项目 `.agents/skills`、`.trha/skills`） |
| rules/ | `rules/*.md` 每次请求追加到系统提示（"Global rules" 段，上限 64 KB） |
| memories/ | `/remember` 追加 `memories/notes.md`；`/memory` 读 `memories/*.md`（兼容旧 `memory.md`） |
| plans/ | 计划快照 `<session-id>.md`（TUI 收到计划即落盘） |
| logs/ | 每日 `trha-YYYYMMDD.log`（0600），记录启动/退出（cli / tui / 模型） |
| backups/ | `settings-<stamp>.yaml` 回滚副本，保留最近 10 个 |
| file-history/ | write/edit 前的文件快照，保留最近 200 个 |
| cache/ | `index-<hash>.json`：`@` 文件补全索引，10 分钟 TTL + 根目录 mtime 失效 |
| state/ | `history`、`frecency.json`、`models.json`、`currency.json`、`stash.jsonl` |
| commands/ | `commands/<name>.md` → `/name`：首行 `# 描述`，正文为提示词，`$ARGUMENTS` 替换；项目 `./.trha/commands` 优先于用户目录 |
| agents/ | `agents/<name>/{preset.yml, AGENT.md}`：`preset.yml` 提供 mode/model/effort/tools，`AGENT.md` 为 instructions；`subagent` 工具的 `agent` 参数按名加载，tools 在请求前过滤 |
| projects/ | `projects/<slug>/{meta.json, sessions.json}`：按工作区的会话索引（`/resume` 优先列本项目），transcript 仍只在 `sessions/` |
| paste/ · voice/ · exports/ | 粘贴图片、语音便签、`/export` 输出 |

### 4.1 项目级 `.trha/`（与 `~/.trha` 对称）

仓库根（含 `.git` 或构建清单的目录）下的 `.trha/` 是**仓库自己的**配置，由用户/团队
自行创建并可入库；`trha setup` **不**创建它（它只管 `~/.trha`）。读取方按需探测，缺失即跳过：

| 项 | 说明 |
|---|---|
| workspace | 一行文本，声明工具工作区（相对"持有 `.trha` 的目录"解析）。scheduler 从 cwd **向上**找最近的一个，所以从 `packages/<pkg>` 启动也能命中仓库根，`{{cwd}}` 不再随启动目录漂移 |
| skills/ | `<name>/SKILL.md`，排在 `~/.trha/skills` 之前 |
| agents/ | `<name>/`，覆盖 `~/.trha/agents/` 的同名定义 |
| commands/ | `commands/<name>.md`，优先于 `~/.trha/commands` |

不入库的运行时产物（`.trha/cache/`、`.trha/tmp/`、`.trha/*.log`、旧版 `.trha-run-*`）
已在根 `.gitignore` 排除；`workspace`、`skills/`、`agents/`、`commands/` 属于项目意图，应当入库。

## 5. 一致性保障（改动必须同步）
1. TS 类型（Server/index.ts ToolEvent 等）↔ CLI `Core.Types`
2. vitest 契约 ↔ hspec 解码测试（同一 JSON 双向 roundtrip）
3. 双 cabal other-modules 同步（root trha.cabal = packages/app/CLI/trha-cli.cabal）
4. 桌面/Web 新客户端按 §2/§3 实现，仅复用协议（不复制 CLI 内部实现）

## 6. 已知限制（协议面）
- 编排层会话为内存态（重启丢失）；CLI 本地 transcript 可回放不可续（服务端无该会话时提示）
- `agent/step` 同步返回聚合 reply；逐 token 流式由 /v1/*stream 提供，外壳经 `/api/events/:sessionId`（SSE）接收（CLI/TUI/Desktop 已接入）
- 工具事件为 demo 注入（真实内核工具执行属 Phase 3 内核深化）
