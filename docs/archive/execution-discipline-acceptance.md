# trha Phase2 S2/S3 执行纪律与验收标准

**依据**: docs/archive/plan-phase2-s2-s3-atomic.md（Planner）+ team-discipline/team-executor 职能
**生效范围**: Phase 2 剩余切片执行（S2、S3、R1-R5）及后续本仓库所有实现工作

---

## 1. 工作纪律（硬性，违反即返工）

### 1.1 证据纪律（防虚假完成）
- **每个完成声明必须附带可复现证据**：测试输出（`cabal test`/`vitest` 行）、构建结果（Linking 行）、冒烟输出。只报"编译通过"而无运行证据 = 未完成。
- 端到端声明必须**实际起服务**（TS + CLI）验证；无 TTY 的 TUI 视觉项必须显式标注 `unverified (需真实终端)`，不得声称已验证。
- 失败时流程：捕获完整错误 → 逐行分析根因 → 修复 → 重测循环；**禁止猜测性多改**。

### 1.2 分层与可测性纪律
- CLI 侧：**纯逻辑（解析/渲染/索引/布局）必须放无 brick/IO 依赖的模块**并配 hspec；brick Widget 只做薄组装。新增纯模块 → 加入 **root `trha.cabal` 与 `packages/app/CLI/trha-cli.cabal` 的 exe other-modules**（双份同步），测试模块加入 CLI 子包 test-suite。
- TS 侧：每个新端点/状态机配 vitest 契约测试；改后 `tsc` 必须零错误。
- 新 JSON/事件字段**向后兼容**（旧数据解析不破坏，缺省值合理）。

### 1.3 代码与命名纪律
- **不删代码**：停用/替换需先写新实现并编译通过，替换关系在总结中列出，删除需用户确认。
- 命名沿用项目既有约定（`TRHA_TOKEN`、trha 品牌、`/` 前缀命令、`recordXxx`/`loadTranscript` 风格）。不引入新缩写体系。
- 临时脚本/产物不入库（用 /tmp）；`dist-newstyle`、`dist/`、`node_modules` 永不手工改。

### 1.4 SSE 与并发纪律（本阶段红线）
- SSE 长连接必须有**取消句柄**，命令退出/会话切换时关闭，禁止泄漏连接。
- 异步线程与 UI 状态更新只经 `BChan`/事件（TUI）或明确回调；禁止在非 UI 线程直接改 brick 状态。
- TS **模拟工具注入必须显式标注 `demo`**（真实工具接入属 Phase 3），不得伪装成真实执行。

### 1.5 范围纪律
- 每个原子任务完成并验证后才进入下一个；纯层（S3-A1/A2 与 S2 纯层）可并行，但**同一文件改动不并发**。
- 超出原子范围的"顺手优化"先记录，不混入当前提交。

---

## 2. 验收标准（Definition of Done）

### 2.1 原子任务级（每项达标才算完成）
| 编号 | 验收 |
|---|---|
| S2-A1 | Core.Types `ToolEvent` 可构造/roundtrip（hspec 绿）；TS 类型 tsc 零错 |
| S2-A2 | vitest：agent/step 在 demo 注入下推送 `tool:update`（running→succeeded+耗时），事件带 sessionId |
| S2-A3 | 起 TS 实测：subscribe 收到事件；返回的取消句柄可停流（连接关闭） |
| S2-A4 | hspec：toolCardLines 状态行/耗时 golden；UI.Brick tool 卡按状态渲染（构建过） |
| S2-A5 | hspec：旧 jsonl 行（无 status）解析不坏；新字段可读 |
| S2-A6 | 冒烟：TS demo 工具 → CLI 显示 `[tool] name` + 状态/耗时 |
| S3-A1 | hspec：构造临时 transcript 目录 → 摘要（id/标题/轮次/模型/时间）正确；空/坏文件容错 |
| S3-A2 | hspec golden：user/assistant/tool 事件 → 回放块；未知事件跳过 |
| S3-A3 | 冒烟：造 transcript → `/resume` 列表 → 选择 → 回放显示 + 续聊或"会话不可继续"提示 |
| S3-A4 | 构建过 + `/resume` 进 TUI picker 候选（视觉项标 unverified） |
| S3-A5 | hspec：`/resume` 在 registry/completions/help；REPL/TUI help 冒烟 |

### 2.2 Merge 回归级（合并前必须全绿）
- **R1** `cabal test`：既有 78 + 新增用例全绿
- **R2** root exe 与 CLI 子包双 `cabal build` 通过
- **R3** TS `npx tsc` 零错误 + `vitest run` 全绿
- **R4** 端到端冒烟：普通消息 + tool 事件（demo）+ `/resume` 回放，输出证据留档
- **R5** 双 cabal other-modules 一致性核对（新增模块两边都在）

### 2.3 交付报告模板（每次合并前填写）
1. 变更清单（文件 × 改动）
2. 证据：测试命令输出 / 构建行 / 冒烟输出
3. 替换关系与停用说明（若有）
4. unverified 清单（明确列出未验证项与原因）
5. 对抗自检记录（薄弱项如何缓解）

---

## 3. 红线（一票否决，不满足即阻塞合入）
1. 无运行证据的完成宣称
2. CLI 纯逻辑无 hspec / TS 端点无契约测试
3. 双 cabal other-modules 不同步
4. SSE 连接无取消句柄或退出泄漏
5. 模拟工具事件未标 demo
6. 旧 transcript/配置数据解析被破坏（向后兼容回归）
