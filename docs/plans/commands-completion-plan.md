# 斜杠命令补全计划（REPL 面 10 条部分实现 → 真实现）

> **状态**：进行中（未开工）。定案来源：`docs/reference/commands-tools-cross-benchmark-2026-11-12.md` §2.1 七方审计。
> **裁定**（用户，2026-11-12）：未实现的命令**补全，不清理**；死代码独立成报告（`docs/reference/dead-code-report-2026-11-12.md`），不在本计划处理。
> **范围**：91 条斜杠命令中审计判定的 10 条部分实现。工具侧缺口（`append_file` 缺声明行）不在本计划，见死代码报告。

## §0 一句话

把 REPL 面的 10 条占位/降级命令补齐到与 TUI 面同等的真实现，并用注册表结构字段 + 编译期穷尽检查防止未来的表面漂移。

## §1 背景与现状

审计（2026-11-12）确认：91 条命令 0 个「仅名字」，但 10 条在 REPL 面是恒定文案、参数丢弃或语义降级（TUI 面均为真实现）。问题模式是**双表面不对称无语义声明**——同一命令两个表面行为不一致，用户在 REPL 得到的是假反馈。

关键复用点（已核实）：
- `copyToClipboard :: Text -> IO Bool`（`UI/Brick/Selection.hs:118`，纯 IO 无 brick 依赖，REPL 可直接用）
- `setInUseProvider`（`Commands/Model.hs:124`，/switch 已用，/provider 可复用）
- `listLocalSessionsIn`（`Core/Transcript.hs`，TUI Home 的 recent 数据源）
- scheduler `index.ts:67`：plugins 目录 **watcher 热重载默认开启**——/reload-plugins 的服务端行为可能已自动发生，语义待核

## §2 原则

1. **补全优先**：除 /reload-plugins 经核实语义已完整的情况外，一律补真实现，不降级不删除。
2. **REPL 的「真」按表面能力定义**：REPL 无对话框/面板，其真实现 = 文本化输出同等信息 + 状态真实变更；不要求像素级对齐 TUI。
3. **每条原子带验收判据**，判据 = trha-cli-test 新增用例的行为断言，不写"看起来好了"。
4. **先加护栏再补全**：T10/T11（注册表表面字段 + 穷尽检查）先行落地，后续补全的命令从第一天就被结构保护。

## §3 里程碑与原子任务

### M1 护栏先行（结构，~1 人日）

| # | 任务 | 落点 | 验收 |
|---|---|---|---|
| T1 | `SlashCommand` 增加 `scSurfaces :: [Surface]` 字段（`data Surface = STui | SRepl`），91 条按审计现状填写（10 条部分实现的 REPL 真补全完成后改全 `[STui, SRepl]`） | `UI/Commands/Registry/Table.hs` | 编译过；`/help`、picker 过滤逻辑按当前表面取候选 |
| T2 | 穷尽检查二选一：(a) 学 haskell-agent `ReplAction`——每命令一个构造子，分发漏分支 = 编译错（改动面大，91 条）；(b) 轻量：`Parser.hs` 分发表数据驱动 + 编译期断言（TH 或 complete-pragma）表内每条命令都有 handler 入口 | `UI/Commands/Registry/Parser.hs` + `Commands.hs` | 删掉任意一条 handler 分支 → 编译失败 |
| T3 | 测试基建：trha-cli-test 增加「注册表↔分发器一致性」property（91 条逐条断言 handler 非恒定文案） | `packages/app/CLI/test/` | 91 条全过；注入一条假占位 → 用例红 |

### M2 REPL 面真实现（5 条高价值，~2.5 人日）

| # | 命令 | 目标行为（REPL 面） | 实现落点 | 验收 |
|---|---|---|---|---|
| T4 | /copy | 复制 REPL 最近一条 assistant 消息：`copyToClipboard` + 失败落 `~/.trha/copy.txt` 回显路径（与 TUI Info.hs:39-47 同语义） | `Commands/Tools.hs:80`；复用 `Selection.hs:118` | 用例：有 assistant 消息 → 返回成功文案且剪贴板内容匹配；无消息 → 提示 |
| T5 | /verbose | REPL 状态加 verbose 标志（影响工具输出是否全文渲染），toggle 后回显新状态 | `Commands/Config.hs:103` + REPL 状态结构（Main.hs 循环状态） | 用例：toggle 两次 → 状态翻转两次；verbose 开启后工具输出含全文 |
| T6 | /home | 渲染最近本地会话（`listLocalSessionsIn`，与 TUI Home 同数据源），标注「resume 用 /resume <id>」 | `Commands/Session.hs:160` | 用例：本地有 ≥1 会话 → 输出含会话 id；空 → 明确提示 |
| T7 | /provider | 无参 = 列表；`/provider <name>` = `setInUseProvider` 切换（复用 /switch 的 Model.hs:124 路径），切换后回显当前 provider | `Commands/Model.hs:102` | 用例：切换到合法 provider → 后续 fetchServiceStatus 反映新值；非法名 → 报错文案 |
| T8 | /clear | 清空 REPL 内存消息缓冲（盘上 transcript 保留），回显「cleared N messages」；清屏行为归 /cls（已存在） | `Commands/Session.hs:105` | 用例：注入 3 条消息 → /clear → 缓冲空、transcript 文件仍在 |

### M3 参数贯通与剩余 3 条（~2.5 人日）

| # | 命令 | 目标行为 | 实现落点 | 验收 |
|---|---|---|---|---|
| T9 | /compact、/compress | `[focus]` 参数贯通：`Bridge.Scheduler.compactSession` 加 focus 参 → scheduler `POST /api/session/:id/compact`（index.ts:2506）确认/补 focus 字段 → 回执含 focus 生效说明 | `Commands/Session.hs:251` + `Bridge/Scheduler.hs` + scheduler 端点 | 用例：带 focus 调用 → 请求体含 focus；服务端响应回填 |
| T10 | /vim | `$EDITOR` 编辑结果**作为下一条 user 消息直接提交**（REPL sendMessage 路径），回显已提交；空结果则放弃 | `Commands/Plan.hs:215` | 用例：编辑器写入文本 → 消息入会话（mock bridge 断言 sendMessage 调用） |
| T11 | /sandbox | 文本化沙箱面板：当前 `TRHA_SANDBOX` 环境值 + 会话权限 posture（fetchSessionMode）+ 配置项，逐行渲染（与 TUI DialogSandbox 信息对齐） | `Commands/Config.hs:177` | 用例：环境值 X → 输出含 X；与 TUI 面板字段一一对应 |
| T12 | /reload-plugins | **语义核实优先**：确认 scheduler watcher（index.ts:67）已热重载 → 命令改为「本地重扫 + `GET /api/plugins` 对账 + 回显差集」；若 watcher 不覆盖某类文件再评估补 `POST /api/plugins/reload` | `Commands/Integration.hs:165` | 用例：本地加一个假 plugin 文件 → 命令后 GET 结果含它 |

## §4 验收总判据（DoD）

1. `cabal test trha-cli-test` 全绿，其中新增 ~18 个用例（T3 一致性 property + T4–T12 各自行为用例）。
2. 审计口径复跑：91 条命令中「部分实现」从 10 → 0（复跑 `docs/reference/commands-tools-cross-benchmark-2026-11-12.md` §2.1 的判定清单）。
3. `scSurfaces` 全部为 `[STui, SRepl]`；不存在恒定文案型 handler（T3 property 长期看门）。
4. `cabal test all` 其余 8 套件不回归。

## §5 风险与依赖

| 风险 | 影响 | 缓解 |
|---|---|---|
| T2 方案 (a) 改动 91 条分发，触碰面大 | 回归风险 | 先落 (b) 轻量版保底；(a) 作为后续独立任务 |
| T9 需 scheduler 端点配合（focus 字段可能不存在） | 跨包改动 | 原子内先核端点；缺则同 PR 内补（TS 侧有测试基建） |
| T12 watcher 语义不可靠 | /reload-plugins 补全落空 | 原子自带核实步骤；不达标则显式补服务端 reload 端点 |
| REPL 状态扩展（T5 verbose、T8 缓冲）触碰 Main.hs 主循环 | 回归风险 | M1 的 property 测试兜底；状态变更走独立记录字段 |

## §6 明确排除

- **死代码清理**（~40 个迁移占位空分支、`/stop` Meta 死分支、`/mouse` 入册、`append_file` 声明行）：不在本计划，见 `docs/reference/dead-code-report-2026-11-12.md`，待单独裁定。
- 工具侧功能增强；TUI 面命令（已全部实现）。
