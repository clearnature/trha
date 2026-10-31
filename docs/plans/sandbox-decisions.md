# 沙箱决策记录（ADR）

> 状态（**2026-10-29 冻结**）：本文件记录沙箱设计中**已拍板**的决策，作为 [`sandbox-architecture.md`](./sandbox-architecture.md) 与 [`sandbox-delivery-plan.md`](./sandbox-delivery-plan.md) 的补充。
> 变更规则：任何修改需新增 ADR（ADR-00x-supersede），不得直接改结论。

## ADR-001 C4：`scopeId = sessionId`

| 项 | 内容 |
|---|---|
| 状态 | **Accepted（2026-10-29）** |
| 背景 | 沙箱按 `Scope` 隔离；内核按 `Session` 组织事件与 checkpoint；scheduler 的 subagent 带 `parentSessionId`。三者需要映射 |
| 决策 | `scopeId = sessionId`；子代理 scope 的 `parent = parentSessionId`；内核不感知 scope |
| 证据 | `Subagent/Manager/Manager.ts:15`（`parentSessionId`）、`Subagent/State/Session.ts:26`（`createSession(subagentId, parentSessionId)`）表明子代理本身就是一个 session |
| 备选 | B：一个 session 拆多个 scope（需 scope 注册表）；C：scope 独立 + 映射表（恢复/重放易漂移）——均放弃 |
| 代价 | 同一会话内并行多个执行域需要未来扩展（当前 trha 无此需求） |
| 判据 | 审计可按 scope 归属；kill 一个 agent 只清理其 scope；子策略继承正确 |
| 复审触发 | 出现「同一 session 内需要并行多个隔离域」的真实需求 |

## ADR-002 工具执行归属：编排层强制 + 内核策略快照校验

| 项 | 内容 |
|---|---|
| 状态 | **Accepted（2026-10-29）** |
| 背景 | 宏内核（工具执行在内核）与编排层强安全内核（scheduler 强制）两条路线 |
| 决策 | 执行留在 scheduler（`executeTool`），沙箱在 `sandboxedSpawn` 强制；内核持有 `policyHash` 快照，每次执行前后校验，不一致记 `sandbox:policydrift` 并拒绝后续执行 |
| 证据 | `Server/index.ts:1810,2276`（`executeTool` 在 scheduler）；`plan-reconciliation.md` 的裁定「内核持有状态、不执行工具、不做业务裁决」 |
| 备选 | 宏内核（把 spawn 移入 Haskell）：与裁定冲突、平台差异进内核、迁移成本高——放弃；纯上报不校验：无法防「静默放宽」——放弃 |
| 代价 | 内核新增一个校验端点（约 3–5 人日）；每次执行多一次校验（可批量/缓存） |
| 判据 | 篡改 `policyHash` 后执行被拒；正常执行无额外可感知延迟（本地缓存命中） |
| 复审触发 | 要求「内核必须亲自 spawn」的合规或部署需求出现 |

## ADR-003 实验对比：留在 host，不内置 `trha experiment diff`

| 项 | 内容 |
|---|---|
| 状态 | **Accepted（2026-10-29）** |
| 背景 | 实验批需要对比结果；旧代码（`xiaorong-chengben`）用 `AblationAnalyzer` 在 Python 侧做 delta 与 markdown |
| 决策 | trha 只产出 `out/`（含 `metrics.json`）+ `repro.json`；对比/绘图由 host 脚本负责 |
| 理由 | 对比逻辑领域相关（ML 指标 vs 物理量），内置会变成第二个「自研周边」——Anthropic 复盘的教训是自研层最易出错 |
| 备选 | 内置 `trha experiment diff`：需先定义通用指标 schema，推迟 |
| 代价 | 用户体验略差，需要外部脚本 |
| 判据 | `out/` + `repro.json` 足以复原任意变体；外部脚本可在 10 行内完成对比 |
| 复审触发 | 半年内出现 ≥3 次重复的对比需求，且指标 schema 已稳定 |

## ADR-004 默认策略：交互式 `WorkspaceWrite`，子代理 `ReadOnly`

| 项 | 内容 |
|---|---|
| 状态 | **Accepted（2026-10-29）** |
| 决策 | 主会话默认 `workspace-write`；子代理默认 `read-only`，需要写时由父 scope `narrow` 显式放宽 |
| 理由 | 与成熟工具一致（dsh 的 fail-safe 默认、ASRT 的写默认拒绝）；子代理是主要的风险放大面 |
| 代价 | 子代理第一次需要写时必须显式配置 |
| 判据 | 新建子代理默认无法写 workspace；显式放宽后探针通过 |
| 复审触发 | 子代理写需求成为常态（>80% 的子代理需要写） |

## ADR-005 工具链只读根：静态表 + 探针

| 项 | 内容 |
|---|---|
| 状态 | **Accepted（2026-10-29）** |
| 决策 | `readonlyRoots` 使用静态默认表（`~/.cabal`、`~/.ghcup`、`/usr`、`/nix/store`、`node_modules`），由探针验证真实构建可用；不做运行时自动探测 |
| 理由 | 自动探测引入不可判据的隐式行为；静态表可审阅、可测试 |
| 代价 | 新工具链（如 Rust、Go 缓存）需要手工加入 |
| 判据 | 探针覆盖 GHC/cargo/node 构建；缺失时给出明确错误 |
| 复审触发 | 静态表维护成本过高（每月 >2 次因缺失路径失败） |

## ADR-006 `Remote` 隔离：本版不实现

| 项 | 内容 |
|---|---|
| 状态 | **Accepted（2026-10-29）** |
| 决策 | `Isolation` 枚举保留 `Remote`，但构造即返回 `SandboxUnavailable`；协议与类型预留 |
| 理由 | 当前无多机/远端需求；保留枚举避免未来破坏性变更 |
| 判据 | 选择 `Remote` 时报错而非静默降级 |
| 复审触发 | 出现远端执行或多租户部署需求 |

## ADR-007 Windows：P4，不提前

| 项 | 内容 |
|---|---|
| 状态 | **Accepted（2026-10-29）** |
| 决策 | Linux/macOS 先行；Windows 受限令牌 + ACL 在 P4，`read-only` 明确标 `partial` |
| 理由 | Win32 成本最高（受限令牌/ACL/Job Object/路径规范化），且不影响主路径验证 |
| 代价 | Windows 用户在前 10 周无沙箱（UI 必须显示「无沙箱」） |
| 判据 | P4 前 Windows 上 `SandboxUnavailable` 明确；P4 后 §6.3 全绿 |
| 复审触发 | Windows 成为主要开发平台 |

---

## ADR-008：资源配额 = prlimit（memory-only）+ wall timeout

| 项 | 内容 |
|---|---|
| 日期 | 2026-10-29 |
| 状态 | ✅ Accepted |
| 背景 | T2.3 要求每 scope 配额（pids/memory/wall）；bwrap 本身没有 rlimit 选项 |
| 参考 | codex/claurst：Linux 侧不做配额；qwen-code：cgroup 只用于**读**宿主内存预算；DeepSeek-Reasonix：Windows 用 Job Object，Linux 无 rlimit |
| 决策 | memory 用 `prlimit --as`（默认 `0` = 不限，显式设置时生效）；wall 用 runner 的 timeout；**pids 不在 Linux 实现**——`RLIMIT_NPROC` 按宿主 uid 的进程数计算，任何低于宿主进程数的值都会让 bwrap 的 `clone` 直接 `EAGAIN`（实测宿主 251724 进程）；pids 留 cgroup v2 扩展点 |
| 代价 | 没有硬 pids 限制（fork 炸弹只能靠 `--unshare-pid` + wall timeout 缓解）；memory 限制是虚拟内存（`RLIMIT_AS`），对 GHC/Node 偏严，故默认关闭 |
| 判据 | 沙箱内 `ulimit -v` = 设定值；默认计划里不出现 `prlimit`；`rlPids` 不映射 `--nproc` |
| 复审触发 | runner 能写 cgroup（systemd user scope 或 root 的 cgroupfs）时，升级为 `pids.max` / `memory.max` 硬限制 |

## ADR-009：network 放行 = `--share-net`（allow）/ 代理环境变量（proxy）

| 项 | 内容 |
|---|---|
| 日期 | 2026-10-29 |
| 状态 | ✅ Accepted |
| 背景 | `NetworkAllow domains` / `NetworkProxy url` 此前只写进配置，渲染器一律 `--unshare-all` 断网 |
| 参考 | codex：布尔 `network_access`；qwen-code：`open/closed/proxied`；DeepSeek-Reasonix：egress 代理桥 |
| 决策 | `NetworkOff`（默认）→ 断网；`NetworkAllow` → `--share-net`（全放行，`domains` 仅记录在 plan/审计，**不强制**）；`NetworkProxy url` → `--share-net` + `HTTP(S)_PROXY`/`http(s)_proxy` 环境变量（best-effort，不阻止直连） |
| 代价 | 没有按域名的 ACL；代理模式不能阻止沙箱直连（真正的强制需要 netns + veth + iptables 或代理桥） |
| 判据 | 同一命令 `getent hosts example.com`：`off` → `NO-DNS`，`allow:` → 解析出地址（2026-10-29 实测）；`proxy:` 的 argv 含四个代理变量 |
| 复审触发 | 需要「只允许白名单域名」时引入代理桥（参考 Reasonix `egress_bridge`），届时 `NetworkProxy` 变为强制模式 |

## ADR-010：pids 配额改走 cgroup v2（supersede ADR-008 的 pids 部分）

| 项 | 内容 |
|---|---|
| 日期 | 2026-10-30 |
| 状态 | ✅ Accepted |
| 背景 | ADR-008 把 pids 排除在 prlimit 之外（`RLIMIT_NPROC` 按宿主 uid 计数，低于宿主进程数会让 bwrap 的 `clone` EAGAIN），只留了「cgroup 扩展点」；但 T2.3 的验收仍要求「并发 N agent 不超全局上限」 |
| 决策 | pids 用 cgroup v2 的 pids 控制器：① **探测**——从 `/proc/self/cgroup` 逐级向上找「能建子目录且子目录带 `pids.max`」的委派目录（systemd 的 `user@UID.service` 通常已委托）；② **执行**——每个 exec 建一个 `trha-<cid>-<pid>` 子 cgroup，写 `pids.max`，spawn 后把 pid 写入 `cgroup.procs`，子进程退出后 `rmdir`；③ **降级**——探测失败不静默：审计写 `AuditError`，`trha sandbox status` 的 `notes` 显示原因。memory 仍用 `prlimit --as`（ADR-008 不变） |
| 代价 | spawn 到写入 `cgroup.procs` 之间有几毫秒竞态：这期间已 fork 的孙进程不在该 cgroup 内；cgroup 依赖 systemd 委托（容器 / 无 systemd 环境会降级为无 pids 限制） |
| 判据 | `test/SandboxCgroupSpec.hs` 全绿：探测、创建/写 `pids.max`/销毁、非法 base 拒绝、`pids.max=4` 下 8 次 fork 让 `pids.events` 出现 `max`（2026-10-30 实测）；`trha sandbox status --json` 的 notes 含 `cgroup pids: <base>` |
| 复审触发 | 需要消除竞态时给 bwrap 加 `--cgroup`（bwrap ≥0.9）或在 runner 里先建 cgroup 再 clone |

## ADR-011：`sandbox.yaml` 是执行期的单一事实来源（limits / readonlyRoots / envAllow）

| 项 | 内容 |
|---|---|
| 日期 | 2026-10-30 |
| 状态 | ✅ Accepted |
| 背景 | `sandbox.yaml` 的 `defaults.limits`、`readonlyRoots`、`envAllow` 只有解析与 `status` 展示，`mkRunnerScope` 硬编码 `defaultResourceLimits` 且 `wrReadOnly = []`。结果是配置「看起来生效、实际不生效」：实测沙箱内 700 个进程全部创建成功、`ulimit -v` 为 unlimited，只有 `/etc` 只读与断网是真的 |
| 决策 | ① runner 读 `~/.trha/sandbox.yaml` 的 `defaults`，构造 `Scope` 时用 `dcLimits`（→ `wrLimits`，驱动 `prlimit --as`、cgroup `pids.max`、默认 wall timeout）、`dcReadonlyRoots`（→ `wrReadOnly`，只读挂载）、`dcEnvAllow`（→ 宿主 env 白名单，注入 `LaunchRequest.lrEnv`）；② `--policy` / `--network` 仍是 CLI 覆盖（scheduler 按 scope 传）；③ 只读根用 `--ro-bind-try`：宿主可能没有 `/nix/store`，严格 `--ro-bind` 会让**整个沙箱无法启动**（实测过一次，教训）；④ env 白名单之外仍叠加凭据前缀过滤，HOME 永远重定向到 scratch |
| 代价 | `limits.memoryMiB > 0` 会真的限制沙箱内进程的虚拟内存（`RLIMIT_AS`）；GHC/Node 的虚拟内存远大于 RSS，2 GiB 能让大型构建失败——ADR-008 已把默认设为 0，用户显式设置时接受该后果 |
| 判据 | 沙箱内 `ulimit -v` 等于 `memoryMiB`；`sandbox.yaml` 里删掉 `/nix/store` 后沙箱仍可启动；`envAllow` 不含的变量不出现在 guest（`--clearenv` + 白名单） |
| 复审触发 | 需要在同一台机器上按 scope 设不同 limits（届时把 `limits` 移入 `ScopeConfig`） |

## ADR-012：读面 = 整根只读 + 凭据目录空 tmpfs（不做完整 allow-list）

| 项 | 内容 |
|---|---|
| 日期 | 2026-10-30 |
| 状态 | ✅ Accepted |
| 背景 | 架构 §2 写「文件读：仅 workspace + 工具链只读根」，但渲染器是 `--ro-bind / /` + 环境变量清洗，宿主 `~/.ssh`、`~/.config`、`/data` 在 guest 内全部可读。完整 allow-list（把 `/` 换成白名单 bind）会破坏 `/etc`、`/usr`、`/proc` 等基础路径，维护成本高 |
| 决策 | 读面保持「整根只读」，另加**静态 deny 列表**（`~/.ssh`、`~/.aws`、`~/.gnupg`、`~/.kube`、`~/.docker`、`~/.config/{gh,gcloud}`）：`LaunchRequest.lrDenyReads` 携带**已存在**的路径（纯渲染器不能 `stat`，由 runner/probe 过滤），渲染成 `--dir p --tmpfs p` |
| 理由 | 与写面的「allow-only」不同，读面的目的是**防凭据外泄**；逐目录屏蔽比整根白名单风险低得多，且列表可审阅（ADR-005 的静态表原则） |
| 代价 | 新增凭据位置需要手工加入；`~/.ssh` 里的 agent socket 也一并不可见（这是有意的） |
| 判据 | `read-ssh` 探针用**宿主绝对路径**（`%HOST_HOME%/.ssh/id_rsa`）并失败；宿主 `~/.ssh` 非空时 guest 内 `ls -A ~/.ssh` 为空 |
| 复审触发 | 需要「只允许读 workspace 与工具链」的强隔离（多租户）时，改整根白名单 + 基础路径静态表 |

## 决策汇总

| ADR | 决策 | 状态 |
|---|---|---|
| 001 | `scopeId = sessionId` | ✅ Accepted |
| 002 | 编排层强制 + 内核策略快照校验 | ✅ Accepted |
| 003 | 实验对比留 host | ✅ Accepted |
| 004 | 交互式 `WorkspaceWrite`、子代理 `ReadOnly` | ✅ Accepted |
| 005 | 工具链静态表 + 探针 | ✅ Accepted |
| 006 | `Remote` 仅预留 | ✅ Accepted |
| 007 | Windows 放 P4 | ✅ Accepted |
| 008 | 配额 prlimit memory-only + wall；pids 留 cgroup | ✅ Accepted（pids 部分由 ADR-010 supersede） |
| 009 | network：allow=share-net，proxy=代理环境变量（非 ACL） | ✅ Accepted |
| 010 | pids 用 cgroup v2（探测委派目录 + 每 exec 一个子 cgroup） | ✅ Accepted |
| 011 | `sandbox.yaml` 的 limits / readonlyRoots / envAllow 是执行期事实来源 | ✅ Accepted |
| 012 | 读面 = 整根只读 + 凭据目录空 tmpfs（不做完整 allow-list） | ✅ Accepted |

> 以上 10 条若需修改，新增 ADR-011 起并注明 supersede 关系。
