# `agents/` 与 `projects/` 目录（已定案 / 已实现）

状态：已实现（2026-10-27）。用户裁定：agents 参考 dsh + Reasonix（目录式 + Markdown instructions），tools 真正生效，projects 仅索引。

## 1. 其他工具怎么做（本机实测）

| 工具 | agent 定义 | 项目状态（projects） |
|---|---|---|
| Claude Code | `plugins/custom-agents/agents/*.md`：YAML frontmatter（`name` / `description` / `model` / `color` / `tools`）+ Markdown 正文即 instructions | `projects/<slug>/①*.jsonl` + `memory/*.md`；slug = 绝对路径把 `/` 换成 `-`（`/home/yanli` → `-home-yanli`） |
| Codex | `agents/*.toml`：`name` / `description` / `sandbox_mode` / `developer_instructions`（整段 Markdown 塞进一个字符串） | 不按项目：`sessions/YYYY/MM/DD/rollout-<时间戳>-<uuid>.jsonl` |
| dsh | `.agent-presets/<name>/`：`preset.yml`（`name` / `description` / `order`）+ `agent.cordis.yml`（插件式 persona、工具、skill 配置） | 不按项目：`sessions/` |
| CodeBuddy | 无 agent 定义（只有 `plugins/` 市场） | `projects/<slug>/{*.jsonl, storage.json}`；`storage.json` 存 UI 状态（`editor.rootPath`、tabs、terminal layout） |
| Reasonix | 无 agent 定义（只有 `skills/`） | 单文件索引 `desktop-projects.json` |
| qwen | 无 | 无 |

三种形态的共同点：

1. **一个 agent 一个文件/目录**，文件名就是 agent 名；
2. **声明式元数据**（model / tools / mode / sandbox）+ **一整段instructions**；
3. 项目状态是**按工作区分目录的索引**（会话文件 + 少量 UI/元数据），不重复存内容。

## 2. trha 现状

- 已有 subagent：`spawnAgent(parent, task, name)`（`Server/index.ts:2295`）。`name` 只是子会话 id 的标签（`<parent>#<name>-<seq>`），子会话**继承父会话的 mode**，没有 persona、tools、model 覆盖。
- 会话存储是扁平的：`sessions/<sid>/transcript.jsonl` + `scheduler-state/session-*.json`。
- `/agents` 显示的是**运行中的会话树**（`AgentEntry`），不是定义。
- `agents/` 目录目前为空壳。

## 3. 草案 A：`~/.trha/agents/<name>.md`

### 文件格式（Markdown + 浅 frontmatter）

```markdown
---
name: reviewer
description: 代码审查：对照计划检查质量与偏差，只报问题不改代码
model: inherit          # inherit | 具体模型名
mode: standard          # trha 的 mode：standard | minimal | ptc | cordis
tools: [read, grep, glob]
effort: medium          # 可选：auto|minimal|low|medium|high
---
你是代码审查子代理。收到任务后：
1. 读计划与改动范围；
2. 逐条对照检查；
3. 只输出问题清单（Critical / Important / Suggestion），不给修改。
```

- 文件名即 agent 名，规则同 `commands/`：`[A-Za-z0-9_-]+`。
- 项目级覆盖：`<cwd>/.trha/agents/<name>.md` 优先于 `~/.trha/agents/`。
- frontmatter 只支持 `key: value` 与 `key: [a, b]` 两种形态（手写 20 行解析，scheduler 不引入 YAML 依赖）。
- 缺 `mode` 时继承父会话；缺 `tools` 时不额外限制。

为什么不选 TOML（Codex 风格）：Node 22 没有内置 TOML 解析器，而 frontmatter 的浅解析足够；更重要的是它与 trha 已有的 `skills/`、`commands/` 都是 Markdown 家族。

### 接入点

| 位置 | 改动 |
|---|---|
| `Server/agentDefs.ts`（新） | `loadAgentDefinitions(dirs)`：解析 `agents/*.md`，返回 `{name, description, model?, mode?, tools?, effort?, instructions}` |
| `Server/index.ts` `spawnAgent` | 新增可选参数 `agentName`：按定义设置 `mode`（子会话 mode）、`effort`、`model`；把 `instructions` 作为子会话的额外 system 段 |
| `subagent` 工具 | 参数增加 `agent`（可选），保持现有 `name`（id 标签）不变，向后兼容 |
| `withSystemPrompt` | 接受 `extraInstructions?: string`，追加在 persona 之后 |
| CLI `/agents` | 分两段：`Defined:`（加载到的定义）+ `Running:`（现有会话树） |
| 命令行 | `/agent <name> <task>`：从当前会话启动一个指定定义的子代理（可选，后做） |

### 工具限制说明

`tools: [read, grep, glob]` 需要 scheduler 在执行子会话时**过滤工具表**（`toolsCfg`）。这比“只写文档”复杂一档：
- 推荐先实现“生效”（否则声明没有意义）；
- 实现方式：`runTurn` 的 tools 列表按定义过滤，未知工具名忽略并告警。

## 4. 草案 B：`~/.trha/projects/<slug>/`

### 布局（只做索引，不复制 transcript）

```
~/.trha/projects/-home-yanli-work-trha/
├── meta.json       { "root": "/home/yanli/work/trha",
│                     "lastSessionId": "...", "lastOpenedAt": "2026-10-27T...Z",
│                     "sessionCount": 12 }
└── sessions.json   [ { "id": "...", "title": "...", "updatedAt": "...",
                       "transcript": "sessions/<id>/transcript.jsonl" } ]
```

- `slug`：绝对路径 `/` → `-`，保留前导 `-`（与 Claude Code 一致，避免 `/a/b` 与 `a/b` 撞名）。
- **不复制** `sessions/<sid>/transcript.jsonl`：那是事实来源，`projects/` 只做“这个工作区有哪些会话”的索引，避免双份存储与不一致。
- 可选 `memory/`：项目级笔记（与 `memories/` 全局笔记区分），先不做。

### 接入点

| 位置 | 改动 |
|---|---|
| `Core/ProjectStore.hs`（新） | `projectSlug :: FilePath -> Text`、`ensureProject :: FilePath -> IO ()`、`recordProjectSession :: FilePath -> SessionSummary -> IO ()`、`projectSessions :: FilePath -> IO [SessionSummary]` |
| `runTUI` / `runCLIMode` 启动 | `ensureProject ws`，刷新 `meta.json` |
| `Core.Transcript.recordSession` | 顺手 upsert 到当前项目的 `sessions.json` |
| `/resume` | 优先列当前项目的会话，其次全局（现有行为） |

### 为什么不做成“每项目一份 transcript”

Claude Code 是每个项目目录下直接放 `*.jsonl`；trha 的 transcript 已经按会话 id 目录组织（`sessions/<sid>/`），再按项目复制会带来双写同步问题。索引方案保留单一事实来源。

## 5. 工作量与顺序

| 步骤 | 内容 | 量级 |
|---|---|---|
| A1 | `agentDefs.ts` + 解析/校验测试 | 小 |
| A2 | `spawnAgent` 接入定义（mode/effort/model）+ 测试 | 中 |
| A3 | `tools` 过滤生效 | 中 |
| A4 | CLI `/agents` 展示定义 + `/agent` 快捷启动 | 小 |
| B1 | `ProjectStore` + `ensureProject` + 测试 | 小 |
| B2 | `recordSession` upsert + `/resume` 按项目优先 | 小-中 |

## 6. 定案与实现状态

1. **agents 格式**：目录式（dsh 的 `.agent-presets/<name>/` 形态）+ Markdown instructions（Reasonix 风格）：
   ```
   ~/.trha/agents/<name>/
   ├── preset.yml     # name / description / mode / model / effort / tools
   └── AGENT.md       # instructions
   ```
   已实现：`Server/agentDefs.ts`（浅 YAML 解析，无新依赖），`subagent` 工具新增 `agent` 参数。
2. **tools 真正生效**：`spawnAgent` 把定义里的 `tools` 作为 `toolsAllow` 传入 `runStep`，工具表在请求前过滤；
   `AGENT.md` 作为 `Agent instructions:` 段追加到子会话系统提示。
3. **projects 仅索引**：`Core/ProjectStore.hs` 维护 `meta.json` + `sessions.json`；`/resume` 把当前项目的会话排在前面；
   transcript 仍只在 `sessions/<id>/transcript.jsonl`。

### 未做（后续）

- CLI `/agents` 区分「已定义」与「运行中」（需要 scheduler 暴露 `GET /api/agents/defs`）。
- `/agent <name> <task>` 快捷启动。
