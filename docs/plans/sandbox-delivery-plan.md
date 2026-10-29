# 沙箱交付计划（WBS · 里程碑 · 质量门禁）

> 状态（**2026-10-29 建档**）：**计划基线，未开工**。设计依据是 [`sandbox-architecture.md`](./sandbox-architecture.md)（接口在 P0 冻结，§5.7）。
> 本文只回答三件事：**拆成什么任务、什么时候交付、什么算完成**。设计问题回架构文档，代码索引见其 §9。

## 0. 范围与前提

| 项 | 约定 |
|---|---|
| 目标 | 让 trha 的工具执行具备 L1 OS 级边界；多智能体按 Scope 隔离；跨平台 fail-closed |
| 不在范围 | L3 语言级沙箱、远端多租户、计费/账户体系（见架构文档 §2.2） |
| 假设 | 单人主开发 + 异步评审；每周 5 个工作日；Docker/bwrap 在本机可用（已实测） |
| 接口纪律 | P0 冻结 §5.7 的类型/协议/端点/配置/CLI；之后只允许新增可选字段、新增 `op`/`kind`、扩展 `capabilities` |
| 估算单位 | 人日（1 人日 = 6 小时有效工作时间）；含自测，不含评审等待 |
| 总计 | **55–60 人日**（含可选 T4.8 的 5 人日），加 30% 缓冲 → **72–78 人日（约 15 周）** |

## 1. 里程碑总览

| 里程碑 | 内容 | 退出标准 | 目标周 |
|---|---|---|---|
| **M0** | 接口冻结 | §5.7.9 文件清单全部存在且可编译；§6.1/§6.2 判据骨架可运行 | ✅ 已完成（2026-10-29） |
| **M1** | Linux Process 级可用 | §6.3 在 Linux 全绿；`TRHA_SANDBOX=on` 时执行点全部走 `sandboxedSpawn`；**默认 `off` 保持现有行为**（兼容默认，2026-10-29 用户裁定 A）；「无沙箱即拒绝」保留为后续目标态（默认切 `on` 时生效） | 第 2–3 周 |
| **M2** | 多智能体作用域 | §6.4 全绿；子代理策略只能收紧；独立 scratch | 第 4 周 |
| **M3** | macOS 可用 | §6.3 在 macOS 全绿（GitHub macOS runner） | 第 5–6 周 |
| **M4** | Windows 可用 | §6.3 在 Windows 全绿；`read-only` 明确标记 `partial` | 第 7–10 周 |
| **M5** | Unix/边缘 + 收尾 | FreeBSD/OpenBSD/边缘 probe 降级可验证；文档与索引完整 | 第 11–13 周 |

> 里程碑是**门禁**，不是日期承诺：上一个未达标不进入下一个。

## 2. WBS

### 2.1 P0 接口冻结（13 项，8 人日，✅ 已完成 2026-10-29）

| ID | 任务 | 产出 | 依赖 | 验收 | 估算 |
|---|---|---|---|---|---|
| T0.1 | `Policy` / `NetworkPolicy` / `ResourceLimits` / `Enforcement` / `PartialReason` | `src/infra/Infrastructure/Sandbox/Policy.hs` | — | 无 `Default Policy`；`DangerFullAccess` 只能显式构造 | 1.0 |
| T0.2 | `Scope` / `Isolation` / `narrow` / `inherit` | `Sandbox/Scope.hs` | T0.1 | `narrow` 返回 `Maybe`；子策略越权为 `Nothing` | 0.5 |
| T0.3 | `LaunchRequest` / `LaunchPlan` / `SandboxError` / `plan` | `Sandbox/Plan.hs` | T0.1、T0.2 | `plan` 纯函数，无 IO | 0.5 |
| T0.4 | `Backend` / `BackendId` / `BackendCapabilities` / `probe` | `Sandbox/Backend.hs`、`Sandbox/Platform.hs` | T0.1 | `Enforcement = Full \| Partial \| None`，无提升函数 | 0.5 |
| T0.5 | 五个平台渲染器 stub | `Backend/{Linux,Mac,Windows,FreeBSD,OpenBSD}.hs` | T0.4 | 未实现时返回 `SandboxUnavailable` | 1.0 |
| T0.6 | NDJSON v1 编解码（11 种帧） | `Sandbox/Protocol.hs` | T0.3 | 帧大小上限、未知 `op` 拒绝、握手版本校验 | 1.0 |
| T0.7 | runner 骨架（spawn + 协议循环） | `Sandbox/Runner.hs` | T0.6 | 握手超时 → 失败；输入管道只读 | 0.5 |
| T0.8 | TS 侧协议与 `sandboxedSpawn` stub | `packages/scheduler/src/Server/{sandbox,sandboxProtocol}.ts` | T0.6 | `tsc --noEmit` 通过 | 0.5 |
| T0.9 | CLI `trha sandbox *` 骨架 | `packages/app/CLI/Core/Sandbox.hs` + `Args.hs`/`Main.hs` | T0.4 | `--help` 列出子命令 | 0.5 |
| T0.10 | `~/.trha/sandbox.yaml` schema + 解析 | `Sandbox/Config.hs` | T0.1 | 未知键报错；`version` 不匹配拒绝 | 0.5 |
| T0.11 | 黄金/属性测试骨架 | `test/Sandbox/PolicySpec.hs` 等 | T0.1–T0.5 | §6.1/§6.2 各至少 1 例 | 0.5 |
| T0.12 | 登记 `trha.cabal` 与 CI 接线 | `trha.cabal`（trha-infra） | T0.1–T0.11 | `cabal build all` 0 error | 0.5 |
| T0.13 | **接线契约 C1–C5**（策略来源/审批交互/事件归属/Scope 映射/降级）+ 工具执行归属裁定 | `docs/contracts/protocol-shell-kernel.md` | T0.1、T0.10 | C2 已确认（不触发审批）；C4 = ADR-001；执行归属 = ADR-002（编排层 + 内核策略快照校验）；结论写入契约文档 | 1.0 |

### 2.2 P1 Linux（9 项，10 人日）

> **P2 进度（2026-10-29）**：T2.1 Scope 树 / `narrow`（既有，`scopeChild`/`inherit`）、T2.2 每 scope `work/` 回收（`runExperiment` 结束后清理，保留 `out/`）、T2.4 命名空间隔离探针（PID/NET：沙箱内 `/proc` 仅本沙箱进程、`/proc/net/tcp` 仅表头）、T2.5 跨 scope 隔离集成测试、T2.7 `runExperiment`（变体 × 种子矩阵、`concurrency`、失败重试新目录、`repro.json`）、T2.8 复现元数据（`reproJson`）、**审计 `experiment: {batch, variant, seed}` 标签（runner `--experiment`）** **已完成**；T2.3 配额（**memory 用 `prlimit --as`，默认关闭；pids 已由 cgroup v2 实现（ADR-010，2026-10-30）：探测 systemd 委派目录 → 每 exec 一个 `trha-<cid>-<pid>` 子 cgroup + `pids.max`，spawn 后写 `cgroup.procs`，退出 `rmdir`；不可用时审计 `AuditError` 且 `trha sandbox status` 的 notes 显示原因，不静默降级**）、T2.4 探针、T2.6 scope 树（scheduler `GET /api/sandbox/scopes`、CLI `trha sandbox scopes`、Desktop `SandboxPanel` 的「作用域/Scopes」行）**已完成**，显示 session/agent 树的 policy/isolation。实验批的 `network` 目前只记录在 `repro.json`，执行阶段仍断网。
>
> **进度（2026-10-29）**：T1.1 bwrap 渲染、T1.2 读写策略、T1.4 runner（含端到端测试）、T1.5 探针、**T1.6 执行点接入（bash / run_code / terminal；`TRHA_SANDBOX=on` 时经 runner，默认 off 保持原行为）**、**T1.7 审计（`~/.trha/logs/sandbox.jsonl`，0600，10 MiB 轮转）**、**T1.8 UI（`/api/sandbox/status` + Desktop 面板显示真实 backend/enforcement/notes；`trha sandbox status --json`、`trha sandbox probe`；TUI 状态栏 `sandbox:off/on` 徽标 + `/sandbox` 交互面板：开关 / 策略 / 网络 / scratch）**、**`/sandbox` 接线闭环：`sandbox.yaml` 新增 `enabled`/`scratch` 与 `saveSandboxConfig`；CLI `sandbox config [--enabled on|off] [--policy] [--network] [--scratch] [--json]`；scheduler `GET/PUT /api/sandbox/config` + 运行时开关（`setSandboxEnabledRuntime`）；TUI 面板经 `setSandboxConfig` 落盘并即时生效**、**复核修复（2026-10-29）：Bug1 `sandboxOn` 死代码（徽标启动读 env 初值 + 异步 `GET /api/sandbox/config` 取运行时 `enabled`）；Bug2 `/status` 的 Sandbox 行改读 env + `sandbox.yaml`（不再是 workspace 路径）**。**审计 deny 结构化（2026-10-29）：runner 把 stderr 的 `Read-only file system` / `Permission denied` / `Operation not permitted` 等转成 `Deny` 帧并写 `AuditDeny` 事件，`sandboxedSpawn.denials` 不再为空**。**network 放行（ADR-009）：`NetworkAllow` → `--share-net` 全放行（domains 仅审计），`NetworkProxy` → 代理环境变量；实测 `off` 无 DNS、`allow:` 可解析。剩余缺口：按域名的强制 ACL 需要代理桥。**、**T1.9 工具链回归（沙箱内 ghc/node 可用）**、`trha sandbox runner` **已完成**；**`terminal_open` 沙箱接入已完成（2026-10-30）**——runner 的 `exec` 不再阻塞帧循环，`stdin` 帧按 id 路由到子进程（`stdin` 句柄登记在 session 表里，`shutdown` 统一回收），drain 改为按块读（交互式提示符没有换行）；scheduler 侧新增 `sandboxedInteractive()`，`terminal_open` 在 `TRHA_SANDBOX=on` 时走它。**语义差异（有意）**：这是「管道 + 长驻 shell」，不是真 PTY——`terminal_signal` 在该模式下终止整个会话而非只给前台进程发信号；真 PTY（`forkpty`）需要 runner 侧再加一层，暂未做。T1.3（Landlock，可选）待做。已知处理：scratch 目录自动创建，沙箱内 `HOME` 指向 scratch，`PATH` 继承宿主。

| ID | 任务 | 依赖 | 验收 | 估算 |
|---|---|---|---|---|
| T1.1 | bwrap 渲染器完整实现（mount 白名单、`--unshare-all`、`--new-session`、`--die-with-parent`） | T0.5 | 黄金测试逐字节稳定 | 1.0 |
| T1.2 | 读/写/临时区策略落地（read allow-list、write allow-only、private-session temp） | T1.1 | 属性测试：writable bind ⊆ 策略根 | 1.0 |
| T1.3 | Landlock（可选，ABI 探测；不可用则 `partial`） | T1.1 | 写入 `~/.ssh` 被拒；ABI 缺失时 `missing` 可见 | 2.0 |
| T1.4 | runner 真实 spawn：流式 stdout/stderr、超时、进程组回收 | T0.7 | 取消后无残留进程 | 1.5 |
| T1.5 | 探针套件（写 `/etc` 失败、workspace 成功、读 `~/.ssh` 失败、断网、fork 炸弹、setsid 逃逸） | T1.4 | §6.3 六例全绿 | 1.5 |
| T1.6 | 接入 5 个执行点（bash、run_code、terminal、terminal_open、win32 PowerShell 分支保留） | T1.4 | 无绕过路径（grep 检查） | 1.0 |
| T1.7 | 审计日志 `sandbox.jsonl`（allow/deny/partial/error） | T1.4 | 轮转、0600、字段符合 §5.7.7 | 0.5 |
| T1.8 | UI 状态（Desktop `SandboxPanel` 显示真实 backend/enforcement）；默认 `off` 走原路径并在 UI 显示 `backend: none` | T1.5 | `off` 时 UI 显示 `none`；`on` 时显示真实 backend | 0.5 |
| T1.9 | 工具链回归（GHC/cargo/node/LSP/PTY/Chrome） | T1.6 | 真实构建与 PTY 交互不被破坏 | 1.0 |

### 2.3 P2 多智能体与实验批（8 项，7.5 人日）

| ID | 任务 | 依赖 | 验收 | 估算 |
|---|---|---|---|---|
| T2.1 | Scope 树与策略继承（`inherit`） | T1.6 | 子代理只能收紧；越权构造期拒绝 | 1.0 |
| T2.2 | 每 scope 独立 scratch + 清理 | T2.1 | kill 后临时目录回收 | 0.5 |
| T2.3 | 每 scope 资源配额（pids/memory/wall） | T2.1 | 并发 N agent 不超全局上限 | 1.0 |
| T2.4 | 通信经宿主校验（禁止沙箱间 fd/socket） | T2.1 | 沙箱内 `ls /proc/self/fd` 无跨 scope 句柄 | 0.5 |
| T2.5 | 跨 scope 探针（A 写 B scratch 必须失败） | T2.2 | §6.4 五例全绿 | 1.0 |
| T2.6 | 作用域审计与 UI（agent 树显示 isolation） | T2.5 | CLI/Desktop 可见 | 0.5 |
| T2.7 | **实验批（消融）编排**：变体 × 种子矩阵、基线只读挂载、`out/` 汇总、批次配额与失败重试；**兼容旧实验脚本**（`configs/sweep/all.yaml` → `ExperimentBatch`，旧脚本以 `--ablations <one>` 单变体模式接入） | T2.2、T2.3 | §6.5 全绿；`xiaorong-chengben` 的 ML 与 He 两套脚本均能以单变体模式跑通 | 2.0 |
| T2.8 | **复现元数据与汇总**：`repro.json`（baseline commit/treeHash、toolchain、policyHash、seed、env） | T2.7 | 同 `(variant, seed)` 重跑可对比；审计按 `batch` 过滤 | 1.0 |

### 2.4 P3 macOS（5 项，5 人日）

| ID | 任务 | 依赖 | 验收 | 估算 |
|---|---|---|---|---|
| T3.1 | SBPL 渲染器（`renderSeatbeltProfile`） | T0.5 | 黄金测试；profile 语法经 `sandbox-exec` 校验 | 1.5 |
| T3.2 | runner 集成（`sandbox-exec -p`） | T3.1 | 启动失败 fail-closed | 0.5 |
| T3.3 | 探针（写 `/etc`、读 `~/.ssh`、断网、workspace 写） | T3.2 | §6.3 在 macOS 全绿 | 1.5 |
| T3.4 | `sandbox-exec` deprecated 兼容（探测 + 明确告警） | T3.2 | 不可用时 `SandboxUnavailable` | 0.5 |
| T3.5 | CI（GitHub macOS runner） | T3.3 | 每次 PR 跑探针 | 1.0 |

### 2.5 P4 Windows（8 项，13–18 人日，缓冲 +50%）

| ID | 任务 | 依赖 | 验收 | 估算 |
|---|---|---|---|---|
| T4.1 | Rust helper 骨架（`trha-sandbox-win.exe`，JSON 协议） | T0.6 | 能在 Windows 上编译并回 `ready` | 2.0 |
| T4.2 | 受限令牌（`CreateRestrictedToken` + `WRITE_RESTRICTED` + restricting SIDs） | T4.1 | 写 workspace 成功、写 `C:\Windows` 失败 | 2.0 |
| T4.3 | ACL 授权（workspace ACE + deny 父目录删除 + Low integrity） | T4.2 | 目录内不可删除/重命名逃逸 | 3.0 |
| T4.4 | Job Object（进程数/内存/`KILL_ON_JOB_CLOSE`） | T4.1 | agent 崩溃后整组回收 | 1.0 |
| T4.5 | 路径规范化（`GetFinalPathNameByHandle`：junction/ADS/8.3） | T4.3 | 专项探针：junction 指向外部被拒 | 2.0 |
| T4.6 | 探针套件（Windows 版 §6.3） | T4.2–T4.5 | 全绿；`read-only` 标 `partial` | 2.0 |
| T4.7 | 签名/分发（helper 与主程序同签名策略） | T4.6 | 安装包可用 | 1.0 |
| T4.8 | 可选：AppContainer/MXC（`Strong`） | T4.6 | 独立评估，不阻塞 M4 | 5.0 |

> **P4 进度（2026-10-30，无 Windows 主机的前提下的最大推进）**
>
> - **T4.1 完成**：`packages/sandbox-win-helper/`（Rust crate `trha-sandbox-win`）。NDJSON v1 帧与 Haskell `Protocol.hs` 逐字对齐，21 个单测在 Linux 上跑绿；两种入口——长驻 NDJSON 模式与 `-- argv` 一次性模式（后者正是 runner 驱动它时的形态）。
> - **T4.4 完成、T4.5 完成**：Job Object（`KILL_ON_JOB_CLOSE` + 可选 `ACTIVE_PROCESS`/`PROCESS_MEMORY`）与 `GetFinalPathNameByHandleW` 路径规范化；`cargo check --target x86_64-pc-windows-gnu` 通过。
> - **T4.2/T4.3 部分完成**：`CreateRestrictedToken`（`DISABLE_MAX_PRIVILEGE|WRITE_RESTRICTED`）与 `grant_directory_write`（`SetEntriesInAclW` + `SetNamedSecurityInfoW`）已实现并通过交叉编译，但**尚未接线到 spawn**——携带令牌需要 `CreateProcessAsUserW` + 可继承 stdio handle，等于重写 spawn 路径，且只能在真机验证。
> - **诚实性修正**：因此 `enforcement` 对两种策略都报 `Partial`（此前 workspace-write 会误报 `Full`）。这是 T4.6 探针通过前唯一诚实的取值。
> - **T4.6 探针集合已定义**：写内 / 写外 / 读密钥 / junction 逃逸 / 网络，外加 read-only 变体（写内也须失败）；4 个用例锁定集合形状。**真机执行仍未发生**，需 Windows runner。
> - **Haskell 侧渲染器完成**：`renderWindows` 把 Scope 策略渲染成 `trha-sandbox-win.exe --workspace … --scratch … --policy … --network … -- argv`，5 个黄金用例在 Linux 上全绿。
> - **剩余**：T4.2/T4.3 接线（+ 真机确定 restricting SID 策略）、T4.6 真机跑通、T4.7 签名分发、T4.8 AppContainer（可选）。

### 2.6 P5 Unix 与边缘（5 项，12 人日，缓冲 +30%）

| ID | 任务 | 依赖 | 验收 | 估算 |
|---|---|---|---|---|
| T5.1 | FreeBSD Capsicum launcher（预开 fd + `cap_enter` + `cap_rights_limit`） | T1.4 | 未经 fd 的路径访问被拒 | 4.0 |
| T5.2 | OpenBSD pledge/unveil launcher | T1.4 | 白名单外 syscall/路径被拒 | 3.0 |
| T5.3 | 边缘 Linux probe 降级（无 userns/Landlock → `partial`/`none`） | T1.5 | 缺失能力可见；命令拒绝执行 | 2.0 |
| T5.4 | VM CI（qemu FreeBSD/OpenBSD） | T5.1、T5.2 | 探针可重复运行 | 2.0 |
| T5.5 | 平台文档与索引收尾 | 全部 | §9 索引与实际文件一致 | 1.0 |

> **P5 进度（2026-10-30，无 BSD 主机的前提下的最大推进）**
>
> - **T5.1 渲染器完成**：`Backend/FreeBSD.hs` 从 stub 改为纯渲染器，生成 `trha-sandbox-bsd --workspace … --scratch … --policy … --network … -- argv`；非 FreeBSD 上 probe fail-closed；`enforcement` 如实报 `Partial`（capsicum 限制的是已开 fd 的 capability，不是路径）。launcher 本体（预开 fd + `cap_enter` + `cap_rights_limit`）未写，是 T5.1 的剩余部分。
> - **T5.2 渲染器完成**：`Backend/OpenBSD.hs` 渲染**语义化**参数，便于黄金测试直接断言：`--pledge "<promises>"` 与 `--unveil "path:perms"`。read-only → `stdio rpath proc exec`；workspace-write 追加 `wpath cpath`；网络放行追加 `inet`；workspace 的 unveil 权限随策略是 `:r` 或 `:rw`，系统路径恒 `:r`。launcher（真正调用 pledge/unveil）同样待写。
> - **T5.3 完成**：新增用例「bwrap 存在但无法 unshare → 降级为 `Partial` 且 notes 可见」；`Enforcement = None` 时拒绝执行由既有用例覆盖。
> - **T5.4 未做**：qemu 跑 FreeBSD/OpenBSD 需要虚拟化环境与镜像分发，不在当前机器能力内。
> - **T5.5 部分**：§9 索引核对留到 M5 收尾统一做。
> - 新增 10 个黄金用例（FreeBSD 3 + OpenBSD 6 + T5.3 降级 1），全部在 Linux 上跑绿。

## 3. 依赖与关键路径

```
T0.1 ─▶ T0.2 ─▶ T0.3 ─▶ T0.6 ─▶ T0.7 ─▶ T1.4 ─▶ T1.5 ─▶ T1.6 ─▶ T2.1 ─▶ T2.5
  │        │        │        │        │                    ▲
  │        │        │        └▶ T0.8  │                    │
  │        │        └▶ T0.4 ─▶ T0.5 ─▶ T1.1 ─▶ T1.2         │
  └▶ T0.10 ─▶ T0.13 ────────────────────────────────────────┘
                    │
                    ├▶ T0.9
                    └▶ T3.2 / T4.1 / T5.1
```

**关键路径**：T0.1 → T0.3 → T0.6 → T0.7 → T1.4 → T1.5 → **T0.13 → T1.6** → T2.1 → T2.5。T0.13（内核/编排接线契约）是 T1.6 的硬前置：契约未定就接入执行点，会在内核边界调整时返工。

## 4. 迭代与节奏

| 项 | 约定 |
|---|---|
| 迭代 | 1 周一个 sprint；sprint 末必须产生**可验证产物**（测试或探针），不接受「只写了代码」 |
| 每日 | 只做当前任务；跨任务发现的问题进 backlog，不顺手扩范围 |
| 评审 | 每个 PR 至少一次自查清单：接口是否冻结、判据是否新增、文档是否同步 |
| 里程碑 | M0–M5 各一次退出评审；未达标不进入下一阶段 |
| 复盘 | 每个里程碑后记录：估算偏差、返工原因、判据缺口 |

## 5. 质量门禁（DoD）

每个任务完成必须同时满足：

| 门禁 | 检查 |
|---|---|
| 编译 | Haskell：`cabal build all` 0 error；TS：`tsc --noEmit` 0 error |
| 测试 | 新增测试通过；既有 `cabal test trha-test trha-cli-test`、相关 `npx vitest run` 全绿 |
| 判据 | 对应 §6 条目（编译期/黄金/探针/多 agent）至少新增 1 条并运行 |
| 接口 | P0 后签名未变；变更需 §7 的 RFC |
| 文档 | 架构文档与本文同步；`docs/README.md` 索引更新 |
| 提交 | Conventional Commits（中文 subject），不混入无关改动 |
| 安全 | 不引入绕过路径（grep 全部 `spawn(` 均经 `sandboxedSpawn`） |

## 6. 变更控制（接口冻结后）

1. **破坏性变更**（改字段语义/删除字段）→ 必须写 RFC（模板见 §6.1），并把协议 `v` 升一级、保留 v1 解码路径。
2. **兼容性变更**（新增可选字段、新 `op`/`kind`）→ 在 PR 描述里列出，并更新 §5.7 与 §9。
3. **后端替换**（如新增 gVisor `Strong`）→ 不改 `Policy`/`Protocol`，只加 `Backend` 实现与 probe 条目。
4. **接口冻结检查**：CI 中对比导出的公开类型签名（Haddock/`ghc -ddump-mini-imports` 或自建脚本），差异必须附 RFC 链接。

### 6.1 RFC 模板

```markdown
# RFC-<n>: <标题>
- 动机：
- 影响面：类型 / 协议 / 配置 / CLI / 后端
- 迁移路径：
- 判据：新增/修改的 §6 条目
- 回滚方案：
```

## 7. 风险与缓冲

| 风险 | 概率 | 影响 | 缓冲 / 应对 |
|---|---|---|---|
| Windows 受限令牌/ACL 比预期复杂 | 高 | M4 延期 | P4 已 +50% 缓冲；必要时先交付 `partial` |
| 工具链在沙箱内失败（GHC/cargo/node） | 中 | M1 延期 | T1.9 提前到 T1.6 之后立即做；只读根用静态表 + 探针 |
| `landlock` 包不可用 | 中 | T1.3 延期 | 作为可选任务，不阻塞 M1 |
| FreeBSD/OpenBSD 无 CI | 中 | T5.4 延期 | 标记 experimental，先手工 VM 验证 |
| 接口在 P1 才发现设计缺陷 | 中 | 返工 | P0 用 stub 跑通全部调用路径；RFC 流程 |
| PTY/Chrome/LSP 兼容 | 中 | 交互体验倒退 | 这些工具可走 `Shared` 并显式标注 |
| 单人开发中断 | 中 | 整体延期 | 每个任务保持可独立合入；文档即上下文 |
| **内核/编排边界调整**（工具执行迁移、事件矩阵扩展、Presentation 接线） | 中 | **接线层返工**（T1.6/T1.8/T2.6） | 先做 T0.13 接线契约并写入 `protocol-shell-kernel.md`；纯层（P0 类型/渲染/协议）不受影响，可先行 |
| **消融实验需要联网下载依赖** | 高 | 默认断网下实验无法启动 | 基线准备阶段联网预热；执行阶段断网；需联网的变体显式声明 `network` |
| **旧实验脚本依赖特定 Python/venv**（如 `pytorch-cuda`） | 中 | 沙箱内解释器不一致导致结果不可复现 | 只读挂载 venv；`repro.json` 记录解释器路径与版本；探针校验 `python -c "import torch"` |

**总缓冲**：30%（含 P4 的 +50% 与 P5 的 +30% 局部缓冲）。

## 8. 度量与报告

| 指标 | 目标 | 采集方式 |
|---|---|---|
| 探针通过率 | 100% | CI 日志 |
| 无沙箱执行次数 | 0 | 审计日志 `event=allow` 且 `backend=none` |
| `enforcement=partial` 比例 | 逐平台下降 | `sandboxStatus()` |
| 接口变更次数（P0 后） | ≤2 次，且均有 RFC | PR 记录 |
| 估算偏差 | 单任务 ≤50%，里程碑 ≤30% | 复盘记录 |
| 回归缺陷 | 每个里程碑 ≤1 | issue 标签 |

## 9. 交付物清单

| 类别 | 交付物 |
|---|---|
| 代码 | `src/infra/Infrastructure/Sandbox/**`（P0 清单）、`packages/scheduler/src/Server/sandbox*.ts`、`packages/app/CLI/Core/Sandbox.hs`、Windows helper（Rust） |
| 测试 | 纯层黄金/属性测试、runner 集成测试、§6.3 探针、§6.4 多 agent 探针 |
| 文档 | 架构文档（已建）、本交付计划、`docs/README.md` 索引、`~/.trha/sandbox.yaml` 示例 |
| 运维 | `trha sandbox status/probe`、审计日志轮转、CI 矩阵（Linux/macOS/Windows/VM） |

### 9.1 P0 实现回执（2026-10-29）

| 项 | 结果 |
|---|---|
| Haskell 模块 | `Infrastructure.Sandbox.{Policy,Scope,Plan,Backend,Error,Protocol,Runner,Config}` + `Backend.{Stub,Linux,Mac,Windows,FreeBSD,OpenBSD}` + 聚合 `Infrastructure.Sandbox` |
| TS 模块 | `packages/scheduler/src/Server/{sandbox,sandboxProtocol}.ts` |
| CLI | `Core.Sandbox` + `CmdSandbox`；`trha sandbox status` 可用，`exec` 拒绝执行（exit 1） |
| 测试 | `trha-test` **231 examples / 0 failures**（含 runner 端到端 3 例、审计 3 例、工具链回归 1 例）；`trha-cli-test` **622 / 0**；`packages/scheduler` `vitest run test/sandbox.test.ts` **10 / 0** |
| 编译 | `cabal build trha`（含 CLI）通过；`packages/scheduler` `npx tsc --noEmit` 通过 |
| 契约 | C1–C5 写入 `docs/contracts/protocol-shell-kernel.md` §1.3 |
| 决策 | ADR-001/002 已落实（C4、执行归属） |

## 10. 与现有文档的关系

| 文档 | 关系 |
|---|---|
| [`sandbox-architecture.md`](./sandbox-architecture.md) | 设计权威：类型、协议、判据、平台矩阵、参考代码索引（§9） |
| [`../architecture/architecture.md`](../architecture/architecture.md) | 结构权威：分层与职责边界 |
| [`../contracts/protocol-shell-kernel.md`](../contracts/protocol-shell-kernel.md) | 跨端协议；沙箱端点需同步登记 |
| 本文 | 执行权威：任务、里程碑、门禁、变更控制 |

## 11. 技能与智能体协作（单人开发）

> 单人开发的真实约束不是「写代码慢」，而是**验证带宽**（没人替你 review）与**上下文膨胀**（长会话越做越糊涂）。本节把可用技能按阶段固定下来，减少临时决策。

### 11.1 技能映射

| 阶段 | 技能 / 工具 | 触发时机 | 产出 |
|---|---|---|---|
| Sprint 开始 | `task-decomposition` + `duration-estimation` + `planning-with-files` | 每个里程碑开始；上个里程碑偏差 >30% | 本周任务表、PERT 三点估算、`task_plan.md` |
| 设计/威胁 | `threat-surface-mapping` | M0 冻结前、M2 Scope 设计前 | 攻击面清单 → 映射到 §6 判据 |
| 实现 | `test-driven-development` | **每个 T 任务开工时，先写测试/探针** | 红灯 → 实现 → 绿灯 |
| 独立调研 | `explore` / `read_only_task` | 需要查跨仓库实现、协议细节 | 结论摘要（不污染主上下文） |
| 可并行任务 | `subagent-driven-development` + `parallel_tasks` | 写路径互不重叠（如 Linux 渲染器 vs TS stub） | 并行 PR，主线程不阻塞 |
| PR 提交前 | `review`（隔离 diff 评审） | 每个 PR | 逐文件问题（正确性/缺测试/隐藏行为） |
| 安全敏感改动 | `security-review` | 涉及策略、路径、协议、权限、凭证 | 注入/路径穿越/凭据/授权检查 |
| 里程碑退出 | `brooks-sweep` + `brooks-test` + `brooks-review` | M0–M5 评审 | 腐化/测试质量/设计味道报告 |
| 会话收尾 | `handoff-memory` + `context_budget` | 每次会话结束 | `HANDOFF.md` 短索引、上下文余量 |

调用方式（手动触发，不自动运行）：`run_skill { name: "<skill>" }`、`review { task: "..." }`、`security_review { task: "..." }`、`explore { task: "..." }`。

### 11.2 效率规则（针对「智能体效率很难说」）

1. **小步可验证**：单任务 ≤ 1 人日，单 PR ≤ 400 行；每个任务至少新增 1 条可运行判据（测试或探针）。
2. **先测试后实现**：用 `test-driven-development` 强制红灯；避免「看起来完成」——这也是本项目历史上「假绿」的教训。
3. **估算按任务记录**：每个任务完成时记录实际耗时；偏差 >50% 的任务进入里程碑复盘，并在下一 sprint 调整。
4. **上下文靠仓库，不靠对话**：`HANDOFF.md` 只放索引/指针（当前里程碑、下一任务、未决问题、证据路径），不放全文；新会话先读它，而不是重述历史。
5. **验证带宽用技能补**：单人没有第二双眼睛，`review` + `security-review` 是固定动作，不因「自己写的」跳过。
6. **独立任务才并行**：只有写路径不重叠时用 `subagent-driven-development`/`parallel_tasks`；共享 `trha.cabal`、`docs/README.md` 的改动串行。
7. **失败即停**：探针失败先修再继续，不带病进入下一任务。

### 11.3 每次会话的固定动作

| 时机 | 动作 | 落点 |
|---|---|---|
| 开工 | 读 `HANDOFF.md` + 本文当前里程碑；`context_budget` 确认余量 | — |
| 任务中 | TDD；只碰当前任务涉及的文件 | — |
| 提交前 | `review`；安全敏感改动加 `security-review` | PR 描述 |
| 收尾 | 更新 `HANDOFF.md`（进度/下一任务/未决）；同步 `task_plan.md` | 仓库 |

### 11.4 与门禁的关系

技能是**门禁的辅助**，不是替代：§5 的 7 条 DoD 仍然逐条检查；`review`/`security-review` 的输出作为 PR 评审证据附在描述里。

### 11.5 高风险任务的三点估算（PERT）

按 `duration-estimation` 的 PERT 方法（`(O + 4M + P) / 6`，标准差 `(P − O) / 6`），对 WBS 中方差最大的 5 项重新估算（单人 + 智能体辅助）：

| 任务 | O | M | P | PERT | σ | 原估算 | 偏差 |
|---|---|---|---|---|---|---|---|
| T1.3 Landlock | 1.0 | 2.0 | 4.0 | **2.2** | 0.50 | 2.0 | +10% |
| T4.2 Windows 受限令牌 | 1.5 | 2.0 | 5.0 | **2.4** | 0.58 | 2.0 | +20% |
| T4.3 Windows ACL | 2.0 | 3.0 | 7.0 | **3.5** | 0.83 | 3.0 | +17% |
| T4.5 Windows 路径规范化 | 1.5 | 2.0 | 6.0 | **2.6** | 0.75 | 2.0 | +30% |
| T5.1 FreeBSD Capsicum | 2.0 | 4.0 | 8.0 | **4.3** | 1.00 | 4.0 | +8% |
| **合计** | | | | **15.0** | 1.65 | 13.0 | **+15%** |

解读：

- 高风险任务 P50 ≈ 15.0 人日，P85 ≈ **16.7 人日**（`15.0 + 1.65`），仍落在 §7 的 30% 总缓冲内。
- 原 WBS 估算整体偏乐观约 **15%**，主要来自 Windows 与路径规范化。
- 智能体辅助降低的是 M（最可能值），不降低 P（悲观值）——验证与返工不会因为智能体而消失。

### 11.6 攻击面清单（按 `threat-surface-mapping` 输出格式）

在 M0 冻结前用该技能产出完整清单；以下是按 L1 边界预填的初版，**每条都要落成 §6 的判据**。

| 类别 | 攻击面 | 可访问性 | 对应判据 |
|---|---|---|---|
| 文件 | symlink / junction / reparse point 逃逸 | 高 | §6.3 Windows junction；§6.2 属性测试 |
| 文件 | workspace 内链接指向外部 | 高 | §6.2 writable bind ⊆ 策略根 |
| 文件 | 共享临时区被其他进程替换 | 中 | §6.3 private-session temp 探针 |
| 文件 | Windows ADS / 8.3 短名绕过 | 高 | §6.3 Windows 专项 |
| 网络 | DNS / 代理绕过 | 中 | §6.3 断网探针 |
| 网络 | **已批准域名外泄**（Anthropic 实例） | 高 | §8「按能力授权」+ 审计 |
| 进程 | `setsid` / 双 fork 逃逸 | 中 | §6.3 进程组回收 |
| 进程 | `/proc` 读取宿主进程 | 中 | `--unshare-pid` 探针 |
| 凭证 | `SSH_AUTH_SOCK`、云凭据、git 凭据 | 高 | §6.3 读 `~/.ssh` 失败；env 清洗 |
| 协议 | 握手降级 / 帧注入 | 中 | 版本校验 + 大小上限 + fuzz |
| 协议 | runner 可执行被替换 | 中 | 路径校验 + digest |
| Scope | 跨 scope 写 scratch | 高 | §6.4 |
| Scope | 子策略提升 | 高 | `narrow` 类型 + 运行时二次校验 |
| Scope | 通信绕过宿主 | 中 | §6.4 fd/socket 扫描 |
| 配置 | **项目级配置在信任前解析**（Anthropic 实例） | 高 | §8 条目 + 专项测试 |
| 供应链 | bwrap / runsc 二进制被替换 | 中 | digest 校验（参考 codex） |

优先级（按预期可利用性）：**路径规范化 → 项目配置信任 → 跨 scope → 凭证 → 允许域名外泄**。这五项在 M1/M2 之前必须有负例探针。
