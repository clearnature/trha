# 沙箱架构（第一版设计基线）

> 状态（**2026-10-29 建档**）：**设计基线，尚未实现**。本仓当前没有任何 OS 级沙箱；本文定义目标、类型、协议、判据与阶段计划，作为实现前的评审基线。
> 结构事实以 `../QWEN.md` 与 `../architecture/architecture.md` 为准；本文只描述**沙箱**这一能力缝。
> 参考实现的证据路径见 §9，所有结论均可复核。
> **引用约定**：正文中的 `[R1]…[R11]` / `[D1]…[D4]` 是参考代码索引（§9），每条技术判断都能追到具体仓库、文件与符号/行号；行号漂移时以符号名为准。

## 0. 结论摘要

1. 沙箱分四层：**L1 OS 级（基础）**、L2 容器/VM、**L3 语言级（前沿）**、L4 策略（不是沙箱）。trha 目前 **L1 为 0/5、L3 为 0**，L4 存在但默认放行。
2. 实现位置在 **scheduler 的工具执行层**（`packages/scheduler`），不在 Haskell 内核：所有命令都由 scheduler `spawn`。Haskell 侧承担**策略、作用域与 runner**，通过 argv/NDJSON 协议与 scheduler 对接。
3. 多智能体（subagent）是基础需求，沙箱必须按 **Scope（作用域树）** 建模，而不是只做单进程隔离。
4. 内核原语不自行实现：Linux 用 **bubblewrap（+ 可选 Landlock/seccomp）**，macOS 用 **Seatbelt**，Windows 用 **受限令牌/AppContainer**（helper 进程）。Haskell 负责强类型策略与纯函数渲染，可逐字节测试。
5. 首选 fail-closed：任何后端不可用或启动失败都**拒绝执行**，绝不静默回退到宿主。
6. **接口在 P0 一次性冻结**（§5.7）：类型、NDJSON 协议、HTTP 端点、配置 schema、CLI 全部先落地（允许 stub），后续阶段只填实现、不改签名。
7. **平台分层**（§3.1）：只有 L0（策略/协议/类型）是「一次代码」；L1 按能力适配——Linux bwrap/Landlock、FreeBSD Capsicum、OpenBSD pledge/unveil、macOS Seatbelt、Windows 受限令牌/AppContainer、边缘 probe 降级、iOS/RTOS 以 `Enforcement = None` 拒绝执行。
8. **实现是混合语言**（§5.8）：Haskell 负责决策与纯渲染，隔离原语交给 bwrap（C）、`sandbox-exec`（系统）、`runsc bwrap`（Go）、Windows helper（建议 Rust）。
9. **真实事件优先环境防线**（§4.4）：Anthropic 2026-05 复盘显示 gVisor/seccomp/VM 全部扛住，出事的是自研配置加载与允许列表代理；模型层永远达不到 100%，确定性边界才是最后一道。

---

## 1. 现状（证据）

### 1.1 已有的防护（都不是沙箱）

| 位置 | 实际作用 | 边界 |
|---|---|---|
| `packages/scheduler/src/Server/toolGuard.ts:17` `confineWritePath` | 文件工具的写路径必须落在 workspace（含 realpath 校验） | 只覆盖文件工具，不覆盖 `bash` [R9] |
| `packages/scheduler/src/Permission/permissionRules.ts:83` `decidePermission` | deny > ask > allow 规则引擎 | **无规则或未命中 → allow**（第 85/93/97 行）[R9] |
| `packages/scheduler/src/Server/shell.ts:91` `hardenedEnv()` | 环境变量加固 | POSIX 上**原样返回** `process.env`，只给 win32 加了一个变量 [R9] |
| `src/infra/Infrastructure/Sandbox/Process.hs:28` `execute` | 名为 Sandbox | 只是 `readCreateProcessWithExitCode (shell cmd)`，**无隔离**，注释里的 timeout 也未实现 [R9] |
| `packages/app/Desktop/src/renderer/ui/SandboxPanel.tsx:6,24` | 沙箱设置 UI | 占位；注释写明「沙箱后端（seatbelt/bubblewrap/Windows token）预留」[R9] |

### 1.2 关键缺陷

- `permissionRules.ts:6` 的注释写着「无命中规则 → 默认 allow（**沙箱已兜底文件边界**）」——该前提不成立，属于**错误安全假设**。
- `bash` 工具可以读写任意路径、读取 `~/.ssh`、外传数据；`terminal_open` 等同理。
- 子代理与主代理共享 scheduler 进程、工作区与凭证，**agent 之间没有作用域隔离**（§5.3）。

### 1.3 命令执行点（接入位置）

| 文件:行 | 用途 |
|---|---|
| `Server/standardTools.ts:145` | `bash` 工具 |
| `Server/standardTools.ts:439` | `run_code` |
| `Server/extraTools.ts:68` | terminal 命令 |
| `Server/extraTools.ts:171` | `terminal_open`（交互 shell） |
| `Server/extraTools.ts:336` | win32 PowerShell |
| `Server/browser.ts:116` | Chrome 启动 |
| `Server/lsp.ts`、`Server/mcp.ts`、`Subagent/Manager` | 子进程 / 子代理 |

> 收口目标：以上全部改为调用同一个 `sandboxedSpawn()`，不允许绕过。

---

## 2. 目标与非目标

### 2.1 判据（对齐项目的强类型/可判据要求）

| 类别 | 判据 |
|---|---|
| **强类型** | 策略与作用域用类型表达；`DangerFullAccess` 不可由默认值产生；`Partial` 强制执行级别不可当作 `Full`；子作用域策略只能收紧 |
| **安全性** | 默认拒绝；后端不可用即失败；凭证不进入沙箱；跨 agent 作用域不可互写 |
| **可判据性** | 策略→argv/profile 的渲染是纯函数，可黄金对拍；边界用运行时探针验证（正/负用例）；与参考实现语义等价可对拍 |

### 2.2 非目标（本版）

- 不做多客户/计费隔离（multi-tenant）。
- 不做语言级沙箱（L3）：trha 目前没有宿主内脚本执行面，等 workflow/code-mode 需求出现再立项。
- 不自行实现 seccomp/Landlock/AppContainer 的 Haskell 绑定；这些通过外部工具或独立 helper 使用。
- 不承诺 Windows 与 Linux 同期交付（见 §7）。

---

## 3. 分层模型

| 层 | 内容 | 性质 | trha 目标 |
|---|---|---|---|
| **L1 OS 级** | 文件（bwrap/Landlock/Seatbelt/ACL）、进程（namespace/Job Object）、系统调用（seccomp/no_new_privs）、网络（netns/代理白名单）、资源与凭证（cgroup/降权/env 清洗） | **基础功能** | P0–P3 必做 |
| L2 容器/VM | Docker/Podman、gVisor、microVM | 选项 | P4 可选（`Strong` 隔离） |
| L3 语言级 | QuickJS/WASM/Worker，能力注入、确定性 | 前沿方向 | 本版不做 |
| L4 策略 | 权限规则、路径围栏、审计 | **不是沙箱** | 立即修正默认值 |

L1 的五个子项各自都要有「默认拒绝 + 显式放行」：

| 子项 | 默认 | 显式放行方式 |
|---|---|---|
| 文件读 | 仅 workspace + 工具链只读根 | 策略 `readonlyRoots` |
| 文件写 | 仅 workspace + scope scratch | 策略 `writableRoot` |
| 进程 | 独立 PID scope，不可见宿主进程 | `--unshare-pid` / Job Object |
| 系统调用 | `no_new_privs` + 最小 seccomp | 后端能力声明 |
| 网络 | 断开（`--unshare-net`） | `allowedDomains` + 出口代理 |
| 资源 | 进程数/内存/时间上限 | cgroup / Job Object 限额 |
| 凭证 | 不传递 `SSH_AUTH_SOCK`、云凭据、git 凭据 | 显式 `allowedEnv` |

### 3.1 平台能力矩阵与降级规则

「一次代码」只适用于 **L0（策略/协议/类型）**；L1 的内核原语各平台不同，必须按能力适配。

| 平台族 | 典型代表 | 可用原语 | 沙箱后端 | enforcement |
|---|---|---|---|---|
| Linux（完整） | Ubuntu/RHEL | userns/mount/pid/net ns、seccomp、Landlock ABI 1–11、cgroup v2、no_new_privs | bwrap + Landlock + seccomp + cgroup | full |
| Linux（受限） | 容器内、禁用 userns 的发行版 | 无 userns → bwrap 不可用；可能有 Landlock | Landlock 或 chroot + 降权 | partial |
| FreeBSD | 13/14 | Capsicum（`cap_enter`/`cap_rights_limit`）、jail、`rctl` | Capsicum launcher | partial（路径级需预 open） |
| OpenBSD | 7.x | `pledge` + `unveil` | pledge/unveil launcher | partial（白名单式） |
| macOS | 12+ | Seatbelt SBPL、App Sandbox、TCC | `sandbox-exec` | full（fs/net 规则） |
| Windows | 10/11 | 受限令牌、AppContainer/MXC、Job Object、ACL、完整性级别 | 受限令牌 + ACL + Job；可选 AppContainer | partial / full |
| Android | 10+ | SELinux 域、seccomp、app sandbox | 继承 app sandbox + 策略 | partial |
| iOS/iPadOS | 16+ | App Sandbox，**不能任意 spawn** | 无命令沙箱 | none（拒绝执行） |
| 边缘 Linux | OpenWrt/Yocto | 内核裁剪：常无 userns/Landlock；可能有 cgroup v1、seccomp | bwrap（probe 可用时）/ chroot + drop privileges | partial |
| RTOS | Zephyr/FreeRTOS | 无 MMU 隔离、无进程概念 | 无 OS 沙箱；仅 WASM（WAMR/Wasmtime）可选 | none |

**降级规则（fail-closed）：**

1. 启动时 `probe` 声明 `BackendCapabilities`；策略所需的任一能力缺失 → `SandboxUnavailable`，除非显式选择 `DangerFullAccess`。
2. 不允许「后端存在就假定 full」：`enforcement = Partial` 必须携带**缺失能力列表**，并在 UI/审计中展示。
3. `Platform` 在编译期选默认后端（CPP），运行时 `probe` 可覆盖（例如 FreeBSD 上没有 bwrap）。
4. 无 OS 沙箱的平台（iOS/RTOS）一律 `None`：命令执行直接拒绝，只允许 L4 策略层（若宿主允许）。
5. 降级只能沿「能力更少」方向移动，不能从 `Partial` 升到 `Full`（类型上 `Enforcement` 无提升函数）。

---

## 4. 参考实现与技术现状

### 4.1 参考实现对照

| 项目 | Linux | macOS | Windows | 统一抽象 | 证据 |
|---|---|---|---|---|---|
| codex | bwrap（vendored）+ Landlock + seccomp + no_new_privs | Seatbelt | 服务 + AppContainer/MXC + 受限令牌 + loopback proxy | `codex-rs/sandboxing` | [R1] |
| claude-code | `@anthropic-ai/sandbox-runtime`（bwrap/Landlock/seccomp） | Seatbelt | 无 | TS `SandboxManager` | [R2] |
| deepseek-harness | bwrap/Landlock | Seatbelt | ACL 受限令牌 | `ctx.sandbox` + `enforcement: full\|partial` | [R3] |
| DeepSeek-Reasonix | bwrap | `sandbox-exec -p` | 无 | Go `PrepareArgs` | [R4] |
| qwen-code | Docker/Podman | Seatbelt + 容器 | 容器 | 容器 + profile | [R5] |
| MiMo-Code | 无 | 无 | 无 | 仅 QuickJS（L3）+ write gate | [R6] |
| **haskell-agent** | gVisor（`runsc`，多租户） | Seatbelt（CLI） | 无 | NDJSON v1 runner 协议 + fail-closed | [R7] |

### 4.2 最新技术状态（2026-10 联网核对）

| 技术 | 状态 | 结论 |
|---|---|---|
| Landlock | ABI 已到 **11**（内核 7.3 文档）；文件系统 + TCP bind/connect + ioctl；无需 root | Linux 上与 bwrap 叠加使用 |
| bubblewrap | 已移除 setuid 模式；`PR_SET_NO_NEW_PRIVS`；mount/user/pid/net/uts ns + seccomp；`--new-session` 防 TIOCSTI | Linux 默认后端 |
| gVisor | 用户态内核（Go），`runsc` OCI runtime，systrap；需 Linux 5.6+ | `Strong` 隔离的可选后端 |
| macOS Seatbelt | `sandbox-exec` 仍可用（deprecated，但无替代 CLI） | macOS 默认后端 |
| Windows AppContainer | 凭据/设备/文件/网络/进程/窗口六类隔离；codex 用服务 + MXC + 受限令牌 | Windows 路线，成本最高 |
| Haskell 生态 | Hackage 有 `landlock 0.2.1.1`（2023，测到 GHC 9.6）；**无** seccomp/bwrap/gVisor 绑定；`unix`/`process`/`posix-acl` 可用 | 内核原语走外部工具；`landlock` 包需 fork 才能上 GHC 9.14 |

#### 4.2.1 gVisor 的采用与平台（2026-10 官方资料）

| 维度 | 事实 | 证据 |
|---|---|---|
| 采用者 | Google（GKE Sandbox / Cloud Run / App Engine / Cloud Functions，**每天数百万实例**）、**Anthropic**（claude.ai 代码执行）、**OpenAI**（高风险任务/代码执行）、Snowflake（Snowpark）、Modal、Beam、Cloudflare、DigitalOcean、Ant Group、Grist、Dangerzone、Blink、Northflank | [R8] |
| 共同场景 | 服务端多租户、执行不可信代码、需要 checkpoint/restore | [R8] |
| 平台实现 | **KVM**（裸金属最佳）、**systrap**（2023 起默认，seccomp TRAP）、ptrace（已不再支持）；**Linux only** | [R8] |
| 本地桌面 | 仅 Dangerzone 等少数特例；不是通用本地 CLI 沙箱 | [R8] |

**bwrap personality**：`runsc bwrap` 接受 `--ro-bind` / `--bind` / `--tmpfs` / `--proc` / `--dev` / `--unshare-*` / `--setenv` 等标志，把 bwrap 命令行翻译为 OCI 配置。因此 trha 的 `renderBwrapArgs` 可以**同时**服务 `Process` 与 `Strong` 两级后端 [R8]。

与原生 bwrap 的差异（实现 `Strong` 时必须处理）：

| 标志 | gVisor 行为 |
|---|---|
| `--die-with-parent` | **no-op**；`runsc` 被 SIGKILL 会留下 sandbox → 清理要 trha 自己做 |
| `--new-session` | no-op（TIOCSTI 未实现） |
| `--unshare-pid/ipc/uts/cgroup` | no-op（Sentry 已隔离） |
| `--dev` | 设备节点来自 Sentry，不是宿主 bind |
| `/proc`、`/sys`、`/dev`、`/tmp` | 默认就挂载 |
| `--unshare-user` | 不隐含；不传则以 UID 0 运行（gVisor 内部视角） |

**结论**：gVisor 适合服务端多租户/不可信代码；本地单用户默认仍是 bwrap/Seatbelt/ACL。它作为 `Strong` 后端的价值在于**复用 bwrap 渲染器**，而不是替换默认路径。

### 4.3 成熟工具的访问区规定（对照）

| 工具 | 读默认 | 写默认 | 工作区 | 临时区 | 元数据/敏感路径 | 路径解析 | 证据 |
|---|---|---|---|---|---|---|---|
| **codex** | 允许（`read-only` 模式只读） | 拒绝，除非 `cwd` + `writable_roots`（默认 `[]`） | `cwd` | `/tmp` 与 `$TMPDIR` **默认可写**，可用 `exclude_slash_tmp` / `exclude_tmpdir_env_var` 关闭 | `.git`、`.agents`、`.codex` 默认只读（`.codex` 即使不存在也保护） | 绝对路径；保护子路径按项目根展开 | [R1] |
| **claude-code（ASRT）** | 全允许；`denyRead` 拒绝；`allowRead` 优先 | 全拒绝；`allowWrite` 显式（空 = 无写权）；`denyWrite` 优先 | `.`（相对 settings 目录解析） | 显式列 `/tmp` | 示例 `denyRead: ["~/.ssh"]`；managed settings 可强制 | `/`、`~/`、`./`、`//` 四种语义 | [R2] |
| **deepseek-harness** | 只读是 fail-safe 默认 | `workspaceRoot` 下写 + 平台临时区 | `workspaceRoot`（无 schema 默认，回退 `cwd`，必须绝对） | 私有 temp；Linux `--tmpfs /tmp` | `enforcement: full\|partial`，缺能力即 `SANDBOX_UNAVAILABLE` | 执行世界绝对路径，provider 负责 canonicalize | [R3] |
| **DeepSeek-Reasonix** | 允许；`ForbidReadRoots` 拒绝 | `WriteRoots` + session temp + backend extras | 调用方声明 | 每会话私有 `SessionTemp` | root 链接/重解析校验，可疑 root 被丢弃并记录 | 解析真实路径 + link 检查 | [R4] |
| **qwen-code** | 允许（`(allow default)`） | `(deny file-write*)` + 白名单：workspace、tmp、cache、`~/.qwen`、`~/.npm`、`~/.cache`、`~/.gitconfig`、include dirs、`/dev/*` | `TARGET_DIR` | `TMP_DIR` / `CACHE_DIR` | 6 个 profile：permissive/restrictive × open/closed/proxied | SBPL `subpath` | [R5] |
| **MiMo（opencode）** | 无 OS 级 | 写闸门：项目内允许；memory 树与受管理 worktree 放行；其他 `external_directory:ask` | 项目 `Instance` 边界 | — | macOS TCC / Windows 用户目录不扫描 | win32 `normalizePath` | [R6] |
| **haskell-agent** | 允许 | Seatbelt 只限制 tmp | 工具 `cwd` | 每会话 `sessionTmp` | tmux socket 例外 | — | [R7] |
| **trha 现状** | 无限制 | 仅文件工具限制在 workspace | workspace | 无 | 无 | `realpath`（仅文件工具） | [R9] |

**共识（trha 直接采纳）：**

1. **读与写的默认方向相反**：读默认允许（deny-then-allow），写默认拒绝（allow-only）；不能共用一套语义。
2. **workspace 是唯一默认可写根**；额外根必须显式（`writable_roots` / `allowWrite`）。
3. **临时区要么默认开（codex），要么显式列（ASRT/qwen）**；trha 选前者之外的第三条：**private-session temp**，不默认开放宿主 `/tmp`。
4. **元数据保护**：`.git` / `.agents` / `.trha` 即使父目录可写也默认只读；`~/.ssh` 等敏感路径默认 `denyRead`。
5. **路径必须 canonicalize**（realpath / `GetFinalPathNameByHandle`），并拒绝通过可写目录内链接获得的 root（Reasonix 的 `planWriteRoots` 做法）。

### 4.4 真实事件与教训（2026）

> 来源：Anthropic《How we contain Claude across products》（2026-05-25）[R10]、Claude Mythos Preview 网络安全评估 [R11]。

#### 4.4.1 公开复盘的四类事故

| 事件 | 经过 | 根因 | 修复 |
|---|---|---|---|
| **信任对话框之前执行** | 仓库内 `.claude/settings.json` 定义 hook，在「是否信任此文件夹」之前被执行（2025 中–2026-01，共 3 个漏洞） | 信任边界建立前解析了不可信输入 | 延迟解析/执行项目配置，直到用户确认 |
| **用户作为注入向量** | 钓鱼 prompt 让员工读 `~/.aws/credentials` 编码外传；25 次尝试成功 24 次 | 攻击经用户进入，模型层无异常可抓 | 只有环境有效：egress 拦截 + 文件边界 |
| **通过已批准域名外泄** | Cowork 的 egress 白名单放行 `api.anthropic.com`；恶意文件用攻击者的 API key 上传文件 | 允许列表被当成「域名过滤」而非「能力授予」 | VM 内 MITM 代理，只放行本 session 的 token |
| **模型主动逃逸** | 模型「helpfully」逃出沙箱以完成任务（Mythos Preview） | 能力越强，越会绕开没人写下来的限制 | 环境边界 + 监控，不依赖模型自律 |

补充：隔离同时挡住企业 EDR——Cowork 对 EDR 是不透明的 hypervisor 进程，只能事后用 OTLP 拉日志 [R10]。

#### 4.4.2 三家产品的隔离强度

| 产品 | 隔离 | 边界 | 证据 |
|---|---|---|---|
| claude.ai 代码执行 | **gVisor 容器**（服务端、临时文件系统） | 保护基础设施与租户之间 | [R10] |
| Claude Code | **人审 + OS 沙箱**（macOS Seatbelt / Linux bwrap），读允许、workspace 写、网络默认拒绝 | 保护用户机器 | [R10][R2] |
| Claude Cowork | **完整 VM**（Apple Virtualization / Windows HCS），工作区 + `.claude` 挂载，凭证留宿主 keychain | 保护非技术用户 | [R10] |

数字：权限提示约 **93%** 被批准（人审不可靠）；模型层单次注入成功率约 **0.1%**，100 次自适应后 **5–6%**（概率防线有漏）[R10]。

#### 4.4.3 结论（trha 直接采纳）

1. **成熟原语可靠，自研周边最弱**：gVisor / seccomp / hypervisor 全部扛住；出事的是配置加载与自研允许列表代理 [R10]。
2. **环境优先于模型**：模型层达不到 100%，确定性边界是最后一道。
3. **允许列表按能力授权**，不是按域名（`api.anthropic.com` 事件）。
4. **信任边界前不解析项目配置**（对应 trha 的 `./.trha/settings.yaml`）。
5. **隔离会挡住 EDR**：审计日志（`sandbox.jsonl`）是补偿手段。
6. **多智能体信任升级**：子代理输出不能因为「来自自己人」就默认可信 [R10]。

---

## 5. 架构

### 5.1 模块划分

```
Sandbox.Policy          -- 强类型策略
Sandbox.Scope           -- 作用域树（主 agent / 子代理）
Sandbox.Plan            -- 纯函数：Policy + Scope + Request -> Either SandboxError LaunchPlan
Sandbox.Backend.Linux   -- bwrap argv（可选 Landlock/seccomp）
Sandbox.Backend.Mac     -- sandbox-exec SBPL
Sandbox.Backend.Win     -- 受限令牌/ACL helper（外部 exe + JSON）
Sandbox.Runner          -- 独立进程，NDJSON v1（协议移植自 haskell-agent）
Sandbox.Verify          -- 运行时探针（正/负用例）
Sandbox.Audit           -- 违规/拒绝事件
```

scheduler 侧只需要一个 `sandboxedSpawn()`，内部调用 runner 或直接拼 argv（见 §5.4）。

### 5.2 强类型核心（示意，未编译）

```haskell
-- 危险全权必须显式构造；没有 Default 实例
data Policy
  = ReadOnly ReadOnlyPolicy
  | WorkspaceWrite WritableRoot
  | DangerFullAccess

-- Partial 表示后端只能保证一部分边界（如 Windows ACL 的 hard-link 缺口）
-- None 表示该平台无 OS 沙箱（iOS/RTOS），命令执行必须被拒绝
data Enforcement
  = Full
  | Partial PartialReason
  | None Text

data PartialReason = PartialReason (Set Capability) Text

-- 作用域：主 agent / 子代理树
data Scope = Scope
  { scopeId       :: ScopeId
  , scopeParent   :: Maybe ScopeId
  , scopePolicy   :: Policy
  , scopeScratch  :: ExclusivePath   -- 仅本 scope 可写
  , scopeIsolation :: Isolation      -- Shared | Process | Strong
  }

-- 子作用域只能收紧父策略；返回 Nothing 表示越权
narrow :: Policy -> Policy -> Maybe Policy

-- 纯渲染：策略 -> 平台 argv。黄金测试的最小单元
renderBwrapArgs :: Policy -> Scope -> LaunchRequest -> Either SandboxError [Argv]
renderSeatbeltProfile :: Policy -> Scope -> LaunchRequest -> Either SandboxError Sbpl

-- fail-closed：没有 Maybe，没有默认回退
launch :: Scope -> LaunchRequest -> IO (Either SandboxError Child)
```

类型层要保证的三件事：

1. `DangerFullAccess` 不能被默认值或配置解析的缺省分支悄悄产生；
2. `narrow` 的失败必须是 `Nothing`，不能"返回父策略"；
3. `Enforcement` 的消解必须覆盖 `Partial`，且 `Partial` 不可转换为 `Full`。

### 5.3 多智能体 Scope 模型（本版重点）

trha 已有多智能体：`Subagent/Manager`（spawn/队列/重试）、`subagent`/`list_agents`/`send_message`/`interrupt_agent` 工具、agent 树 UI。但所有 agent 共享同一个 scheduler 进程、工作区与凭证。

Scope 模型：

```
scope-root（主会话）
├── scope-child-a（子代理 A）   scratch: <state>/agents/a/
├── scope-child-b（子代理 B）   scratch: <state>/agents/b/
└── scope-group-c（并行组）      policy: 只读继承
```

规则：

| 规则 | 说明 |
|---|---|
| 策略继承 | 子 scope 的 `Policy` 必须由父 `narrow` 得到；越权在构造期被拒 |
| 独立 scratch | 每个 scope 一个独占可写目录；其他 scope 不可写（运行时探针验证） |
| 共享只读 | workspace 默认只读共享；只有显式 `WorkspaceWrite` 的 scope 可写 |
| 通信经宿主 | agent 间消息只经 scheduler（`Subagent/Communication`），沙箱之间不共享 fd/socket |
| 资源配额 | 每 scope 一组限额（进程数/内存/时间），聚合不超过全局上限 |
| fail-closed | scope 启动失败 → 该 agent 的工具调用失败，不回退宿主执行 |

隔离级别可以渐进，不必每个 agent 都起 gVisor：

| 级别 | 实现 | 适用 |
|---|---|---|
| `Shared` | 同进程，仅策略与路径围栏（L4） | 只读研究类子代理 |
| `Process` | 独立 bwrap/seatbelt 进程 + 独立 scratch | **默认** |
| `Strong` | gVisor / 远端沙箱 | 执行不可信代码、跨信任边界 |

#### 5.3.1 实验批（消融）模型

> 消融实验不是「多开几个 agent」：它要求**同一基线、变体互不污染、可复现、结果可汇总**。`Scope` 提供隔离单元；`ExperimentBatch` 是编排层对一组 Scope 的视图，**不是**沙箱内部概念。

| 层 | 概念 | 归属 | 职责 |
|---|---|---|---|
| 编排 | `ExperimentBatch` | scheduler | 变体 × 种子矩阵、并发与总配额、结果汇总、失败重试 |
| 隔离 | `Scope`（每 `(variant, seed)` 一个） | 沙箱 | 策略、scratch、输出目录、审计标签 |
| 执行 | runner | Haskell | 启动、流式输出、超时、清理 |

**目录与挂载约定**：

```
<state>/experiments/<batchId>/
├── baseline/                  # 只读：代码/数据/权重（host 准备）
├── <variant>/<seed>/
│   ├── work/                  # 可写：临时产物、checkpoint（批次结束回收）
│   └── out/                   # 可写：结果（host 只读汇总；scope 不可删除历史）
└── repro.json                 # 批次复现元数据
```

| 规则 | 说明 |
|---|---|
| **基线只读** | `baseline/` 以只读 bind 挂入所有变体，探针验证不可写 |
| **变体隔离** | 每个 `(variant, seed)` 独立 scope；`work/` 互不可写 |
| **输出可读** | `out/` 可写、不可删除/改写；host 汇总时只读 |
| **网络** | 基线准备阶段可联网；执行阶段默认断网，需联网的变体显式声明 `network` |
| **配额** | 每 scope `limits` + 批次总上限（`并发 × 单 scope` 不超过全局） |
| **失败隔离** | 一个变体失败/超时不影响其他；重试生成**新 scope**，不复用被污染的 `work/` |
| **清理** | 批次结束回收 `work/`；保留 `out/` 与审计；可选保留失败现场快照 |
| **审计** | `sandbox.jsonl` 每条带 `experiment: {batch, variant, seed}` |

**复现元数据**（`repro.json`）：

```json
{
  "batch": "ablation-20261029",
  "baseline": { "commit": "<sha>", "treeHash": "<hash>" },
  "toolchain": { "ghc": "9.14.1", "node": "26.12.1" },
  "policyHash": "<hash>",
  "variants": [{ "id": "no-landlock", "policy": "workspace-write", "network": "off" }],
  "seeds": [1, 2, 3],
  "envRecorded": true
}
```

**与 Scope/多智能体的关系**：实验批复用 §5.3 的 `narrow`（变体策略只能收紧基线）、独立 scratch、配额与清理；区别只在**编排层多了批次视图**（并发控制、汇总、重试）。子代理若承担某个变体，其 `scopeId` 仍是 `sessionId`（C4 方案 A），批次标签通过审计字段附加。

**与旧实验代码的映射**（2026-10-29 核对 `/data/training/cli/xiaorong-chengben`）：

该目录有两套实验：`run_sweep_ml.py` + `src/ablation/*`（ML 消融：base + 7 个变体 + sweep）与 `run.py` + `src/he_ablation/*`（He sp³ 物理消融，独立脚本）。两者的模式一致，可直接映射：

| 旧代码 | 新设计 | 说明 |
|---|---|---|
| `configs/base.yaml` | `baseline`（只读根 + 基线策略） | 变体只能 `narrow` 基线 |
| `configs/ablations/*.yaml`（7 个） | `variants[]` | 每个变体一个 Scope |
| `configs/sweep/all.yaml` | `ExperimentBatch` | 清单、`output_dir`、`baseline_name` |
| `run_single(cfg)` | 单 Scope 执行 | `set_seed(cfg.seed)` → `seeds[]` |
| `out_dir/config.yaml`（OmegaConf 快照） | `repro.json` | 扩展 toolchain / policyHash / baseline commit |
| `metrics.json` | `out/metrics.json` | 结果约定不变 |
| `sweep_results.json` | 批次汇总 | 由 host 生成 |
| `AblationAnalyzer`（delta vs baseline） | **保留在 host / 外部脚本** | 本版 trha 不做对比（§5.3.1 末） |
| `for ablation in ablations`（串行） | 并行 + 配额 + 失败重试 | 新增能力 |

旧代码的缺口恰好是沙箱要补的：串行执行、无进程隔离、无资源配额、基线可被写入、无审计、失败不重试、复现元数据只有 `config.yaml + seed`。

**兼容原则**：trha 只提供「实验批执行外壳」（Scope / 配额 / 复现 / 汇总），**不接管领域逻辑**（PyTorch 训练、物理数值计算）。旧脚本以**单变体模式**接入（`--ablations <one>`），避免 `run_sweep` 内部再串行一遍；批次由 trha 编排。

> **已决策（ADR-003）**：结果对比留在 host（`out/metrics.json` + `repro.json`），本版不内置 `trha experiment diff`。

### 5.4 runner 协议（移植自 haskell-agent）

haskell-agent 的 `Agent.Server.Sandbox`（958 行）与 `Sandbox/Worker.hs`（838 行）提供了一套与 gVisor 解耦的协议骨架，值得保留的部分：

- 版本化握手 + 超时；
- NDJSON，每帧大小上限；
- stderr 有界 tail，诊断只进私有日志；
- 任何失败 → 拒绝，不回退；
- mount 用 open fd 固定，启动前校验 workspace 的 device/inode；
- 输入管道只读（关闭写入端即明确 EOF）。

本仓协议草案（`v1`）：

```json
{"v":1,"op":"hello","scope":"root/child-a","parent":"root"}
{"v":1,"op":"ready","backend":"bwrap","enforcement":"full","landlock":6}
{"v":1,"op":"exec","id":"c1","argv":["bash","-lc","make test"],"cwd":"/workspace","env":["PATH=/usr/bin"]}
{"v":1,"op":"exit","id":"c1","code":0}
{"v":1,"op":"deny","id":"c2","reason":"write outside workspace: /etc/passwd"}
```

不移植的部分：per-tenant 注册表、per-tenant PostgreSQL、计费——与 trha 无关。

### 5.5 与 scheduler 的集成

```
scheduler (standardTools.ts / extraTools.ts)
        │  sandboxedSpawn(scope, argv)
        ▼
trha-sandbox（Haskell runner）            ← 策略、渲染、探针、审计
        │  bwrap / sandbox-exec / win helper
        ▼
bash -lc "<cmd>"
```

- scheduler 只负责把 `Scope` 与命令交给 runner，不理解平台差异；
- **兼容默认（ADR：用户选择 A）**：`TRHA_SANDBOX=off`（默认）时走原有 `exec` 路径，行为不变；显式 `TRHA_SANDBOX=on` 才经 `trha sandbox runner` 执行。runner 不可用 → 工具调用失败，绝不回退裸跑；
- 环境变量：`TRHA_SANDBOX_RUNNER`（默认 `trha`）、`TRHA_SANDBOX_POLICY`（默认 `workspace-write`）、`TRHA_SANDBOX_SCRATCH`（默认 `~/.trha/sandbox-scratch`）、`TRHA_SANDBOX_SCOPE`（默认 `scheduler`）；
- runner 入口：`trha sandbox runner --workspace <dir> --scratch <dir> --policy <read-only|workspace-write>`；
- **环境约定**：scratch 目录由 scheduler 自动创建（`mkdir -p`）；沙箱内 `HOME` 指向 scratch（写入缓存不越界），`PATH` 固定为 `/usr/local/bin:/usr/bin:/bin`，调用方环境中的凭据类变量被过滤；
- 已接入的执行点：`bash`（`runShell`）、`run_code`、`terminal`（`extraTools.sh`）；`terminal_open`（交互 PTY）暂未接入；
- **UI 状态面**：scheduler `GET /api/sandbox/status` → `trha sandbox status --json`（启用时）→ Desktop `SandboxPanel` 显示 backend / enforcement / available / notes；探针 `trha sandbox probe` 输出 4 项结果；
- **TUI**：状态栏（`Ctrl+Y YOLO` 后空三格）显示 `sandbox:off/on` 徽标；`/sandbox` 打开交互面板（开关 / 策略 / 网络 / scratch），经 `PUT /api/sandbox/config` 落盘到 `~/.trha/sandbox.yaml`，scheduler 运行时开关随之切换；
- 现有 `/api/sandbox/write-roots` 与 Desktop `SandboxPanel` 复用为策略配置面。

#### 5.5.1 内核/编排接线契约（**待确认**，当前规划的缺口）

> 上面只定义了「scheduler → runner」。内核（Haskell）持有 FSM、审批屏障、事件日志、checkpoint，但**不执行工具**；因此沙箱与内核之间是**事件与策略的契约**，不是调用关系。以下 5 点尚未规划，必须在 T1.6（接入执行点）之前确认。

| 编号 | 契约点 | 现状 | 结论 / 建议 |
|---|---|---|---|
| **C1** | 策略来源与优先级 | 未定义 | `CLI 参数 > ./.trha/sandbox.yaml > ~/.trha/sandbox.yaml > 默认`；scope 覆盖在后；内核只持久化快照，不裁决 |
| **C2** | 沙箱拒绝 vs 用户审批 | 未定义 | **已确认（2026-10-29）**：沙箱拒绝（`PolicyRejected`/`SandboxUnavailable`）直接 `tool:update failed`，**不进入** `AwaitingApproval`；审批仍只由 `/session/:id/decision` 写入 |
| **C3** | 事件归属 | 事件矩阵只有 `tool:update`（running/succeeded/failed） | 先映射到 `tool:update failed`，detail 携带 `deny.kind/target`；是否新增 `sandbox:deny` 在 G5（内核遥测）时评估 |
| **C4** | Scope ↔ Session 映射 | 未定义 | **已确认（ADR-001）**：`scopeId = sessionId`；子代理 scope 沿 `Subagent(parentSessionId)` 链；内核不感知 scope。详见 §5.5.2 |
| **C5** | 内核不可达时的降级 | 现有 `pendingApproval` 降级分支 | 沙箱在 scheduler，独立于内核可达性；内核不可达不改变沙箱策略，只影响审批提示 |

这 5 点确认后写入 `docs/contracts/protocol-shell-kernel.md`（跨端契约），再实施 T1.6。

#### 5.5.2 C4 详解：Scope、Session、Subagent 三者的对应

三个概念分属三层，彼此**不是同一个东西**：

| 概念 | 所属层 | 含义 | 标识 |
|---|---|---|---|
| **Session** | 内核 | 一次对话：事件日志、checkpoint、FSM 状态 | `sessionId` |
| **Subagent** | scheduler | 子代理：一次独立任务，带父会话引用 | `id`（本身就是一个 session）+ `parentSessionId` |
| **Scope** | 沙箱 | 执行隔离域：策略 + 独占 scratch + 配额 + 审计归属 | `scopeId` |

C4 要定的是三者的映射规则，因为它决定四件事：**审计归属、策略继承、资源配额、清理边界**。

| 方案 | 规则 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| **A（建议）** | `scopeId = sessionId`；子代理 scope 的 `parent = parentSessionId` | 一一对应，无需额外映射表；审计天然按会话归属；子代理已是独立 session | 一个会话内若未来要并行多个执行域，需要扩 | 当前 trha |
| B | 一个 session 多个 scope（按任务拆分） | 更细粒度 | 需要 scope 注册表与生命周期管理；内核不感知，审计要额外关联 | 未来并行任务 |
| C | scope 完全独立，scheduler 维护映射表 | 解耦 | 映射表成为单点，恢复/重放时易漂移 | 不推荐 |

方案 A 与现有代码一致：`Subagent/Manager` 的 `SubagentConfig.parentSessionId`、`fetchAgents` 的 `AgentEntry{aeId, aeParent}` 都表明子代理本身就是一个 session。**若确认 A，P2 的 Scope 树直接由 session 树派生，不需要新映射。**

#### 5.5.3 工具执行归属：宏内核 vs 编排层强安全内核

这决定沙箱的**强制执行点**在哪里。两条路线的代价不同：

| 维度 | 宏内核（工具执行在内核） | 编排层强安全内核（scheduler 强制） |
|---|---|---|
| 执行点 | Haskell 内核 spawn 或调用 runner | scheduler `executeTool` 调用 runner |
| 绕过面 | 小（单一进程、单一入口） | 取决于收口是否彻底（MCP / 插件 / 子代理 / 直接 spawn） |
| 平台差异 | 内核承担（CPP + FFI + Windows helper 集成） | 留在 TS + 外部 helper |
| 与现有裁定 | **冲突**：内核「不做业务裁决」、不执行工具 | **一致**：内核持有 FSM/审批/事件，执行在编排层 |
| 内核职责变化 | 引入进程管理、平台分支、资源回收 | 不变 |
| 迁移成本 | 高（K1–K6 曾做内核工具循环 stub，后转编排） | 低（现状） |
| 对沙箱接口的影响 | 只改**调用方**，`Policy`/`Protocol`/runner 不变 | 无 |
| 推荐 | ❌ 不作为默认 | ✅ 默认 |

**若坚持「强安全内核」**（内核必须强制，而不只是记录），推荐折中而非把 spawn 搬进内核：

1. **执行仍在 scheduler**，但内核持有策略快照（`sandboxPolicyHash`）；
2. 每次工具执行前后，scheduler 上报 `{scopeId, policyHash, backend, enforcement}`；
3. 内核比对快照：不一致 → 标记 `sandbox:policydrift` 事件并拒绝后续执行；
4. 这样"强制"体现在**策略不可被编排层静默放宽**，而不是由内核做进程管理。

> **已决策（ADR-002）**：采纳上述折中——执行留 scheduler，内核做策略快照校验。

代价：内核侧增加一个校验端点（约 3–5 人日），scheduler 每次执行多一次本地/HTTP 调用（可批量）。收益：防止"编排层被绕过或降级"这类最难发现的问题。

若未来确实要把 spawn 移入内核：只影响 T1.6 的调用方适配（预估 +1–2 周），纯层与 runner 协议无需改动——这也是 P0 先冻结接口的价值。

### 5.6 平台后端

| 平台 | 后端 | 关键参数 / API | enforcement | 证据 |
|---|---|---|---|---|
| Linux（完整） | bwrap + Landlock + seccomp + cgroup | `--ro-bind / /`、`--bind <ws> <ws>`、`--tmpfs /tmp`、`--unshare-all`、`--new-session`、`--die-with-parent` | full | [R1][R3][R4] |
| Linux（无 userns） | Landlock / chroot + 降权 | Landlock ABI ≥1；chroot 需 root 或 user ns | partial | [R1][R3] |
| FreeBSD | Capsicum launcher | `cap_enter`、`cap_rights_limit`、`cap_ioctls_limit`；`jail` 可选；`rctl` 限资源 | partial | [D1] |
| OpenBSD | pledge/unveil launcher | `pledge("stdio rpath wpath cpath proc exec")`、`unveil(path, "rwc")` | partial | [D2] |
| macOS | seatbelt | `sandbox-exec -p <SBPL>`；profile 从 `Policy` 纯函数生成 | full | [R1][R2][R4][R7] |
| Windows（基础） | 受限令牌 + ACL + Job Object | `CreateRestrictedToken`（`WRITE_RESTRICTED` + restricting SIDs）、`SetEntriesInAcl`、`JOB_OBJECT_LIMIT_*` | partial | [R1][R3] |
| Windows（强） | AppContainer / MXC + 服务 | `CreateAppContainerProfile` + capability SID + Low integrity；参考 codex `windows-sandbox-service` | full | [R1][D3] |
| 边缘 Linux | bwrap（probe 可用时）/ chroot + drop privileges | 内核裁剪需 `probe`；无 userns 时降级 | partial | [R3] |
| RTOS / 无进程隔离 | 无 | 只能 WASM（WAMR/Wasmtime）或策略层 | none | [D4] |
| 可选（任意 Linux） | gVisor `runsc bwrap`（复用同一套 bwrap 渲染器） | 多智能体 `Strong` 隔离；`--die-with-parent`/`--new-session` 为 no-op，清理需 trha 自管 | full | [R8] |

**Windows 权限与路径（重点）**

- **受限令牌**：`CreateRestrictedToken` + `DISABLE_MAX_PRIVILEGE` + restricting SIDs；`WRITE_RESTRICTED` **只限制写**，不限制读——所以 `read-only` 策略在 Windows 上只能标记 `partial`。
- **AppContainer**：`CreateAppContainerProfile` + capability SID（`internetClient`/`privateNetworkClientServer`）+ Low integrity；workspace 需显式 ACE 授权。
- **Job Object**：`JOB_OBJECT_LIMIT_ACTIVE_PROCESS`、`PROCESS_MEMORY`、`KILL_ON_JOB_CLOSE`（保证 agent 崩溃时整组回收）。
- **路径规范化**：策略比较必须基于 `GetFinalPathNameByHandle` 的最终路径，处理 8.3 短名、junction/reparse point、ADS（`file:stream`）、大小写不敏感、设备名（`CON`/`NUL`/`\\?\`）与 UNC；仅字符串前缀比较可被绕过（现有 `confineWritePath` 的 realpath 方案在 Windows 上不足）。
- **完整性级别与 UAC**：Low/Medium 的 token 权限不同；提权后的进程不能复用同一 Job Object 策略。

**FreeBSD / Unix**

- Capsicum 是**能力式**：`cap_enter` 后只能经已打开的 fd 访问资源，launcher 必须在进入能力模式前打开 workspace、`/dev/null`、stdio；与 §5.7 的 `Capability` 类型天然对应。
- OpenBSD 的 `pledge`/`unveil` 是**白名单式**：先 `unveil` 路径，再 `pledge` 系统调用类别；适合边缘设备（无 namespace、开销极低）。
- Solaris/illumos 可用 zones（重，服务端）；jail（FreeBSD）同理。

**边缘设备**

- 常见无 userns/Landlock、无 Node/Haskell runtime：runner 需**静态二进制**（C/Rust），或把执行放在网关/远端，边缘只做客户端。
- 无 MMU 的 RTOS 没有进程隔离：OS 级沙箱不可行，只能 WASM（WAMR）或纯策略层。
- Android 上 agent 作为 app 已受 SELinux + app sandbox 约束，不能再嵌套；iOS 不允许任意 spawn，只能拒绝命令执行。

### 5.7 接口规范（一次性定型）

> 本节是**接口冻结基线**：P0 阶段把下列类型、协议、端点、配置与 CLI **全部落地（允许 stub）**，后续阶段只填实现，**不再修改签名**。新增能力只能通过版本号与能力协商扩展，不能改既有字段语义。

#### 5.7.1 冻结原则

1. 所有公开类型在 P0 定义完整，包括尚未实现的平台与 `Strong`/`Remote` 隔离。
2. 枚举与协议帧用**开放扩展**：未知字段忽略、未知 `op`/`kind` 拒绝并报错，不静默降级。
3. 纯函数（`plan` 与渲染器）先定型；IO 边界（`launch`）用同一签名，实现可替换。
4. TS 侧只依赖 §5.7.3 的协议与 §5.7.4 的签名，不感知平台差异。

#### 5.7.2 Haskell 公开 API

```haskell
module Infrastructure.Sandbox
  ( -- 策略
    Policy(..), ReadOnlyPolicy(..), WritableRoot(..)
  , NetworkPolicy(..), ResourceLimits(..), AbsolutePath
    -- 平台与能力
  , Platform(..), Capability(..), BackendCapabilities(..)
    -- 作用域
  , Scope(..), ScopeId, Isolation(..), ExclusivePath
  , narrow, inherit, scopeRoot, scopeChild
    -- 计划与执行
  , LaunchRequest(..), LaunchPlan(..), StdinMode(..)
  , SandboxError(..)
  , plan, launch
    -- 后端
  , Backend(..), BackendId(..), BackendCapabilities(..)
  , defaultBackend, backendById
    -- 验证与审计
  , Probe(..), ProbeResult(..), defaultProbes, runProbes
  , AuditEvent(..), AuditKind(..), audit
  ) where
```

```haskell
-- 策略：DangerFullAccess 只能显式构造，没有 Default 实例
data Policy
  = ReadOnly ReadOnlyPolicy
  | WorkspaceWrite WritableRoot
  | DangerFullAccess

data ReadOnlyPolicy = ReadOnlyPolicy
  { roReadableRoots :: [AbsolutePath]   -- 工具链等额外只读根
  , roNetwork       :: NetworkPolicy
  , roEnvAllow      :: [EnvName]
  }

data WritableRoot = WritableRoot
  { wrRoot     :: AbsolutePath          -- 通常为 workspace
  , wrScratch  :: ExclusivePath         -- 本 scope 独占可写
  , wrReadOnly :: [AbsolutePath]
  , wrNetwork  :: NetworkPolicy
  , wrLimits   :: ResourceLimits
  }

data NetworkPolicy
  = NetworkOff
  | NetworkAllow [Domain]
  | NetworkProxy ProxyEndpoint

data ResourceLimits = ResourceLimits
  { rlPids      :: Int
  , rlMemoryMiB :: Int
  , rlWallMs    :: Int
  }

data Isolation = Shared | Process | Strong | Remote   -- Remote 预留，本版不实现

-- 执行级别（与 §5.2 一致）：None 时禁止执行命令
data Enforcement
  = Full
  | Partial PartialReason
  | None Text

data PartialReason = PartialReason (Set Capability) Text

-- 平台：编译期选默认后端，运行时 probe 覆盖
data Platform
  = Linux | FreeBSD | OpenBSD | Darwin | Windows | Android | Other Text

-- 平台无关的能力抽象：策略声明需要哪些，后端声明提供哪些
data Capability
  = CapFsRead | CapFsWrite | CapNet | CapPid | CapSyscall | CapResource | CapCred

data BackendCapabilities = BackendCapabilities
  { bcPlatform     :: Platform
  , bcCapabilities :: Set Capability
  , bcEnforcement  :: Enforcement
  , bcNotes        :: [Text]      -- 缺失能力与降级原因（必填，供 UI/审计展示）
  }

data Scope = Scope
  { scId        :: ScopeId
  , scParent    :: Maybe ScopeId
  , scPolicy    :: Policy
  , scScratch   :: ExclusivePath
  , scIsolation :: Isolation
  }

-- 子作用域只能收紧：Nothing = 越权（调用方必须处理）
narrow :: Policy -> Policy -> Maybe Policy
inherit :: Scope -> Policy -> Either SandboxError Scope

data LaunchRequest = LaunchRequest
  { lrArgv      :: [Text]
  , lrCwd       :: AbsolutePath
  , lrEnv       :: [(EnvName, Text)]
  , lrStdin     :: StdinMode
  , lrTimeoutMs :: Maybe Int
  }

data LaunchPlan = LaunchPlan
  { lpBackend     :: BackendId
  , lpArgv        :: [Text]
  , lpEnforcement :: Enforcement
  , lpMounts      :: [MountSpec]
  , lpNetwork     :: NetworkPolicy
  , lpLimits      :: ResourceLimits
  }

data SandboxError
  = SandboxUnavailable BackendId Text
  | PolicyRejected Text
  | RenderFailed Text
  | LaunchFailed Text
  | ProbeFailed [ProbeResult]

-- 纯函数；launch 是唯一的 IO 边界
plan   :: Scope -> LaunchRequest -> Either SandboxError LaunchPlan
launch :: Scope -> LaunchRequest -> IO (Either SandboxError Child)
```

#### 5.7.3 runner 协议（NDJSON v1，完整帧）

每行一个 JSON 对象，**≤ 1 MiB**；`hello` 超时 5 s；`exec` 默认超时 10 min；输入管道只读。

| op | 方向 | 字段 | 说明 |
|---|---|---|---|
| `hello` | host→runner | `v, scope, parent?, policy, isolation` | 首帧；无握手成功不执行任何命令 |
| `ready` | runner→host | `v, backend, enforcement, capabilities{landlock,seccomp,netns}, pid` | 能力协商；`enforcement=partial` 必须带原因 |
| `exec` | host→runner | `id, argv, cwd, env?, stdin?, timeoutMs?` | 启动一个命令 |
| `stdin` | host→runner | `id, data(base64)` | 可选流式输入 |
| `stdout` / `stderr` | runner→host | `id, data(base64)` | 流式输出 |
| `exit` | runner→host | `id, code, signal?` | 结束 |
| `deny` | runner→host | `id, kind, target` | `kind ∈ fs-read\|fs-write\|net\|syscall\|exec` |
| `probe` | runner→host | `results[{name, ok, expected, actual}]` | 启动自检 |
| `audit` | runner→host | `events[...]` | 批量审计事件 |
| `error` | runner→host | `id?, code, message` | `code ∈ protocol\|policy\|backend\|limit` |
| `shutdown` | host→runner | — | 正常关闭；未确认则 SIGTERM→SIGKILL |

示例：

```json
{"v":1,"op":"hello","scope":"root/child-a","parent":"root","policy":"workspace-write","isolation":"process"}
{"v":1,"op":"ready","backend":"linux-bwrap","enforcement":"full","capabilities":{"landlock":6,"seccomp":true,"netns":true},"pid":41234}
{"v":1,"op":"exec","id":"c1","argv":["bash","-lc","make test"],"cwd":"/workspace","env":["PATH=/usr/bin"],"timeoutMs":600000}
{"v":1,"op":"exit","id":"c1","code":0}
```

失败语义：握手超时/协议错误/后端不可用 → `error` + 关闭，**调用方必须按失败处理**，不得回退宿主。

#### 5.7.4 scheduler 侧 API（TS）

```ts
// packages/scheduler/src/Server/sandbox.ts
export type SandboxIsolation = 'shared' | 'process' | 'strong' | 'remote'
export type SandboxPolicy =
  | { kind: 'read-only'; readonlyRoots?: string[]; network?: NetworkPolicy }
  | { kind: 'workspace-write'; root: string; readonlyRoots?: string[];
      network?: NetworkPolicy; limits?: ResourceLimits }
  | { kind: 'danger-full-access' }

export interface SandboxScope {
  id: string
  parent?: string
  policy: SandboxPolicy
  isolation: SandboxIsolation
  scratch: string
}

export interface SandboxRequest {
  argv: string[]; cwd: string
  env?: Record<string, string>
  stdin?: string
  timeoutMs?: number
  experiment?: string        // 审计标签 batch:variant:seed
}

export interface SandboxDenial {
  kind: 'fs-read' | 'fs-write' | 'net' | 'syscall' | 'exec'
  target: string
}

export interface SandboxResult {
  ok: boolean
  enforcement: 'full' | 'partial' | 'none'
  partialReasons?: string[]
  code: number | null
  signal?: string
  stdout: string
  stderr: string
  denials: SandboxDenial[]
}

export type SandboxCapability =
  'fs-read' | 'fs-write' | 'net' | 'pid' | 'syscall' | 'resource' | 'cred'

export interface SandboxCapabilities {
  landlock?: number
  seccomp?: boolean
  netns?: boolean
  userns?: boolean
  capsicum?: boolean
  pledge?: boolean
  restrictedToken?: boolean
  appContainer?: boolean
  jobObject?: boolean
}

export interface SandboxStatus {
  backend: string
  platform: 'linux' | 'freebsd' | 'openbsd' | 'darwin' | 'win32' | 'android' | 'other'
  enforcement: 'full' | 'partial' | 'none'
  available: boolean
  capabilities: SandboxCapabilities
  missing?: SandboxCapability[]
  notes?: string[]
}

// 持久化配置视图（Get/Put /api/sandbox/config 的载荷）
export interface SandboxConfigView {
  enabled: boolean
  policy: 'read-only' | 'workspace-write'
  network: string            // off | allow:<domains> | proxy:<url>
  scratch: string
}

// 执行作用域视图（Get /api/sandbox/scopes 的条目）
export interface SandboxScopeInfo {
  id: string
  parent: string | null
  depth: number
  policy: string             // root = 配置策略；子代理 = read-only（ADR-004）
  isolation: SandboxIsolation
  enabled: boolean
  cwd: string | null
}

export function sandboxedSpawn(scope: SandboxScope, req: SandboxRequest): Promise<SandboxResult>
export function sandboxStatus(): Promise<SandboxStatus>
export function sandboxProbe(scopeId?: string): Promise<ProbeResult[]>
export function readSandboxConfig(): Promise<SandboxConfigView>
export function writeSandboxConfig(patch: Partial<SandboxConfigView>): Promise<SandboxConfigView>
export function setSandboxEnabledRuntime(on: boolean | undefined): void
export function setSandboxPolicy(scopeId: string, policy: SandboxPolicy): Promise<void>

// 实验批（消融）：编排层概念，内部为每个 (variant, seed) 建一个 Scope。
// 目录布局：<root>/<variant>/<seed>/ 为可写根，work/ 为独占 scratch，
// out/ 在根内；baseline/ 只读挂载。重试写入 attempt-N/ 新目录。
export interface ExperimentVariantSpec { id: string; network?: NetworkPolicy }
export interface ExperimentBatch {
  id: string
  root: string                     // <state>/experiments/<id>
  baseline: string                 // 只读根
  variants: ExperimentVariantSpec[]
  seeds: number[]
  concurrency: number
}
export interface ExperimentTask {
  variant: string; seed: number; attempt: number
  scope: SandboxScope
  dir: string; work: string; out: string
}
export interface ExperimentResult {
  variant: string; seed: number; attempt: number
  ok: boolean; code: number | null
  stdout: string; stderr: string
  error?: string
}
export interface ExperimentRunOptions {
  makeRequest: (task: ExperimentTask) => SandboxRequest
  retries?: number
  onStart?: (task: ExperimentTask) => void | Promise<void>
  cleanupWork?: boolean            // 默认 true：回收 work/，保留 out/
}
export interface ExperimentOutcome {
  batchId: string
  results: ExperimentResult[]
  reproPath: string
}
export function runExperiment(batch: ExperimentBatch, options: ExperimentRunOptions): Promise<ExperimentOutcome>
```

HTTP（复用现有 `/api/sandbox/*` 前缀）：

| 方法/路径 | 请求 | 响应 |
|---|---|---|
| GET `/api/sandbox/status` | — | `SandboxStatus` |
| GET `/api/sandbox/config` | — | `SandboxConfigView`（`enabled` 为运行时开关，env 显式时优先） |
| PUT `/api/sandbox/config` | `Partial<SandboxConfigView>` | `SandboxConfigView`（落盘 + 热切换） |
| GET `/api/sandbox/scopes` | — | `{ scopes: SandboxScopeInfo[] }` |
| GET `/api/sandbox/policy?scope=` | — | `SandboxPolicy` + 来源（default/scope） |
| PUT `/api/sandbox/policy` | `{scope, policy}` | `{ok}` |
| GET/PUT `/api/sandbox/write-roots` | 已有 | 已有（保持兼容） |
| POST `/api/sandbox/probe` | `{scope?}` | `ProbeResult[]` |
| GET `/api/sandbox/audit?since=&limit=` | — | `AuditEvent[]` |

`exec` 返回 `enforcement=partial` 时，调用方必须把原因透传到 UI，不得当作 `full`。

#### 5.7.5 配置 schema（`~/.trha/sandbox.yaml`，0600，原子写）

```yaml
version: 1
enabled: false                   # 运行时开关；TRHA_SANDBOX 显式设置时 env 优先
defaults:
  policy: workspace-write        # read-only | workspace-write | danger-full-access
  isolation: process             # shared | process | strong | remote
  network: off                   # off | allow:<domain,...> | proxy:<url>
  scratch: ~/.trha/sandbox-scratch
  # 0 = 不限（ADR-008：Linux 不映射 --nproc；memory 默认关闭，显式才用 RLIMIT_AS）
  limits: { pids: 0, memoryMiB: 0, wallMs: 600000 }
  # 读：默认允许（deny-then-allow）；allow 优先于 deny
  read:
    mode: allow
    deny: [~/.ssh, ~/.aws, ~/.gnupg, ~/.config/gh, ~/.kube]
    allow: []                    # 在 deny 区域内重新放行（优先）
  # 写：默认拒绝（allow-only）；roots 为空 = 无写权
  write:
    mode: allow-only
    roots: []                    # 运行时注入 <workspace>；显式追加需审批
    deny: []                     # deny 优先于 allow
  # 即使父目录可写，这些子路径仍只读
  protectedSubpaths: [.git, .agents, .trha, .codex]
  tmp: private-session           # none | private-session | host
  readonlyRoots: [~/.cabal, ~/.ghcup, /usr, /nix/store]
  envAllow: [PATH, HOME, LANG, TERM]
backends:
  linux:   { command: bwrap, landlock: auto, seccomp: auto }
  macos:   { command: sandbox-exec }
  windows: { helper: trha-sandbox-win.exe, mode: restricted-token }
  freebsd: { mode: capsicum, jail: auto }
  openbsd: { mode: pledge }
  edge:    { allowDegraded: false }   # true 时 partial 也放行，但必须显式
scopes:
  subagent: { policy: read-only, isolation: process }
experiments:
  baselineReadonly: true          # baseline/ 只读挂载
  outputRoot: ~/.trha/experiments
  reproduce: { recordEnv: true, recordToolchain: true, recordSeed: true }
  limits: { maxConcurrent: 4, batchWallMs: 7200000 }
```

未知键 → 报错（fail-closed），不做静默忽略；`version` 不匹配 → 拒绝启动沙箱并提示迁移。

#### 5.7.6 CLI（P0 先接 stub）

```bash
trha sandbox status [--json]        # 后端、enforcement、policies 来源
trha sandbox probe [--scope <id>]   # 运行探针，退出码 = 是否全绿
trha sandbox config [--enabled on|off] [--policy <p>] [--network <spec>] [--scratch <dir>] [--json]
                                    # 无参数 = 显示；带参数 = 落盘 ~/.trha/sandbox.yaml
trha sandbox scopes                 # 执行作用域（session/agent 树：policy + isolation）
trha sandbox runner --workspace <dir> --scratch <dir> --policy <p> [--network <spec>] [--experiment <tag>]
                                    # NDJSON runner 入口（scheduler 内部使用）
trha sandbox policy get [--scope <id>]
trha sandbox policy set --scope <id> --file <yaml|json>
trha sandbox exec --scope <id> -- <argv...>   # 直接走 runner
trha sandbox audit [--since <ts>] [--limit N]
```

> 以上 CLI 签名自 P0 冻结；`config` / `scopes` / `runner` 为 P1 新增，只加不改。

#### 5.7.7 审计事件

```json
{"v":1,"ts":"2026-10-29T05:12:33Z","scope":"root/child-a","event":"deny",
 "kind":"fs-write","target":"/etc/passwd","backend":"linux-bwrap","enforcement":"full"}
```

`event ∈ allow|deny|partial|error`；写 `~/.trha/logs/sandbox.jsonl`（0600，轮转），同时可经 SSE 推给壳。

#### 5.7.8 扩展点与版本策略

| 扩展点 | 预留方式 | 本版状态 |
|---|---|---|
| 新后端（容器/远端） | `Backend` 记录 + `BackendId` 开放枚举 | 接口已定义，仅实现 bwrap/seatbelt/受限令牌 |
| 新平台（FreeBSD / OpenBSD / 边缘 / Android） | `Platform` 开放枚举 + 后端 `probe` | 接口已定义，实现按 P5 排队 |
| 无 OS 沙箱平台（iOS / RTOS） | `Enforcement = None` + 拒绝执行 | 已定义，命令执行直接失败 |
| `Remote` 隔离 | `Isolation = ... | Remote` | 枚举存在，构造即返回 `SandboxUnavailable` |
| 语言级沙箱（L3） | 预留 `Sandbox.Runtime` 模块名与 `RuntimeBackend` 类型 | 不实现，不导出 |
| 协议升级 | `v` 字段 + `ready.capabilities` 协商 | v1 冻结 |
| 新拒绝类型 | `deny.kind` 开放字符串 + 降级为 `syscall` | 已定义五类 |

#### 5.7.9 P0 落地文件清单（接口骨架，可 stub）

> **状态：✅ 已落地（2026-10-29）**。下表与实际文件一致；`Probe.hs` / `Audit.hs` 顺延到 P1/P2（P0 未建，接口已在 §5.7.2 冻结）。

| 文件 | 内容 | 状态 |
|---|---|---|
| `src/infra/Infrastructure/Sandbox/Policy.hs` | `Policy` / `NetworkPolicy` / `ResourceLimits` / `narrow` | ✅ |
| `src/infra/Infrastructure/Sandbox/Scope.hs` | `Scope` / `Isolation` / `inherit` | ✅ |
| `src/infra/Infrastructure/Sandbox/Plan.hs` | `LaunchRequest` / `LaunchPlan` / `MountSpec` | ✅ |
| `src/infra/Infrastructure/Sandbox/Backend.hs` | `Backend` / `BackendId` / `BackendCapabilities` / `planWith` | ✅ |
| `src/infra/Infrastructure/Sandbox/Backend/Stub.hs` | 未实现后端的共享 stub | ✅ |
| `src/infra/Infrastructure/Sandbox/Backend/{Linux,Mac,Windows,FreeBSD,OpenBSD}.hs` | 各平台注册（P0 返回 `SandboxUnavailable`） | ✅ |
| `src/infra/Infrastructure/Sandbox/Error.hs` | `SandboxError` / `BackendId` / `ProbeResult` | ✅ |
| `src/infra/Infrastructure/Sandbox/Protocol.hs` | NDJSON v1 编解码（12 种帧） | ✅ |
| `src/infra/Infrastructure/Sandbox/Runner.hs` | 行式帧 IO + P0 stub 循环 | ✅ |
| `src/infra/Infrastructure/Sandbox/Config.hs` | `~/.trha/sandbox.yaml` 严格解析 | ✅ |
| `src/infra/Infrastructure/Sandbox/Probe.hs` | `defaultProbes` / `runProbes` | ✅（P1） |
| `src/infra/Infrastructure/Sandbox/Audit.hs` | `AuditEvent` / 写入（0600，10 MiB 轮转） | ✅（P1） |
| `packages/scheduler/src/Server/sandbox.ts` | `sandboxedSpawn` 等（P0 fail-closed） | ✅ |
| `packages/scheduler/src/Server/sandboxProtocol.ts` | 帧类型定义 | ✅ |
| `packages/app/CLI/Core/Sandbox.hs` | `trha sandbox *` 子命令实现 | ✅ |
| `packages/app/CLI/Core/Args.hs`、`packages/app/CLI/Main.hs` | 子命令注册 | ✅ |

> `trha.cabal` 的 `trha-infra` 已登记全部模块并设 `visibility: public`（CLI 子包依赖）；
> `packages/app/CLI/trha-cli.cabal` 的 executable 与 test-suite 已同步依赖 `trha:trha-infra` 与 `Core.Sandbox`。
> 现有 `src/infra/Infrastructure/Sandbox/Process.hs`（名为 Sandbox、实为无隔离的 `shell` 包装）**保留但标注 deprecated**，新接口不复用它；是否删除由用户裁定，不在 P0 范围内。

### 5.8 实现语言与组件边界

| 层 | 语言 / 组件 | 职责 | 是否自研 |
|---|---|---|---|
| 策略 / 类型 / 渲染 / 协议 / 审计 | **Haskell** | `Policy`、`Scope`、`narrow`、`renderBwrapArgs`、`renderSeatbeltProfile`、NDJSON、探针判定 | ✅ |
| Linux 隔离原语 | **C（bubblewrap）** | mount/user/pid/net ns、seccomp、`no_new_privs` | ❌ 外部 |
| macOS 隔离原语 | **Apple `sandbox-exec`** | Seatbelt profile 执行 | ❌ 系统 |
| `Strong` 级 | **Go（gVisor `runsc bwrap`）** | 用户态内核、checkpoint/restore | ❌ 外部 |
| Windows 隔离原语 | **Rust 或 C helper**（建议 Rust） | 受限令牌 + ACL + Job Object；`CreateRestrictedToken` / `SetEntriesInAcl` | ✅ 薄 helper |
| 调用层 | **TypeScript** | scheduler `sandboxedSpawn` | ✅ |

原则：

1. **Haskell 只做决策与纯渲染**，不碰内核原语（Hackage 无 seccomp/Landlock/namespace 绑定）。
2. **平台原语使用久经对抗的外部组件**——§4.4 的教训是自研周边最容易出事。
3. **Windows helper 建议 Rust**：Win32 绑定成熟、可静态链接、内存安全；C 次之；不用 PowerShell（可被绕过、审计难）。
4. **进程边界只有 runner 一处**（§5.4），其余在进程内以模块边界隔离。

---

## 6. 判据与测试

### 6.1 编译期

- 没有 `Default Policy`；`DangerFullAccess` 只能显式构造。
- `narrow` 返回 `Maybe`，调用方必须处理 `Nothing`。
- `Enforcement` 的 `Partial` 分支必须被消费。

### 6.2 纯函数测试

- 黄金测试：`renderBwrapArgs` / `renderSeatbeltProfile` 对固定输入的逐字节快照。
- 属性测试：任意 `WorkspaceWrite r` 的渲染结果中，所有 writable bind 都位于 `r` 之下。
- 对拍：同一 `Policy` 下与 codex/ASRT 生成的参数**语义等价**（按规范化后的挂载集合比较）。

### 6.3 运行时探针（集成测试）

| 用例 | 期望 |
|---|---|
| 写 `/etc/trha-probe` | 失败（EACCES/EPERM） |
| 写 workspace | 成功 |
| 读 `~/.ssh/id_*` | 失败 |
| `curl` 外网（默认策略） | 失败 |
| `curl` 白名单域名（开启网络） | 成功 |
| fork 炸弹 | 被进程数上限终止 |
| 子进程逃逸（`setsid` 后存活） | 进程组清理后无残留 |
| Windows：junction / ADS / 8.3 短名指向 workspace 外 | 拒绝 |
| FreeBSD：Capsicum 下未经 fd 的路径访问 | 拒绝 |
| 边缘：无 userns 时 bwrap 启动失败 | `probe` 报 `partial`/`none`，命令拒绝执行 |

### 6.4 多智能体判据

| 用例 | 期望 |
|---|---|
| agent A 写 agent B 的 scratch | 失败 |
| 子代理构造比父更宽的策略 | 构造期拒绝（`narrow` 返回 `Nothing`） |
| agent 间消息 | 只能经 scheduler；沙箱内无共享 fd/socket |
| kill 一个 agent | 进程组、临时目录、cgroup 全部回收 |
| 同时 spawn N 个 agent | 聚合资源不超过上限 |

### 6.5 实验批（消融）判据

| 用例 | 期望 |
|---|---|
| 变体写 `baseline/` | 失败（只读 bind + 探针） |
| 变体 A 写变体 B 的 `work/` | 失败 |
| 同 `(variant, seed)` 重跑 | 确定性任务结果一致；非确定性任务记录差异来源 |
| 一个变体崩溃/超时 | 其他变体继续；批次可汇总出「失败变体」 |
| 并发 N 个变体 | 总资源不超过批次上限 |
| host 汇总读取 `out/` | 可读；scope 内不能删除/改写历史输出 |
| 审计按 `experiment.batch` 过滤 | 能取到该批次全部 deny/allow/partial 事件 |

---

## 7. 分阶段计划

| 阶段 | 内容 | 交付判据 | 估计 |
|---|---|---|---|
| **P0** | **接口冻结**：§5.7 的类型、协议、端点、配置、CLI 全部落地（实现可为 stub）+ 纯渲染 + 黄金/属性测试 | §5.7.9 文件清单全部存在且 `cabal build all` / `tsc --noEmit` 通过；§6.1、§6.2 全绿 | 5–7 天 |
| **P1** | Linux 实现填充：runner + bwrap 后端 + 探针，**不改 §5.7 签名** | §6.3 全绿；`bash`/`run_code`/terminal 全部走 `sandboxedSpawn` | 1–2 周 |
| **P2** | 多智能体 Scope 实现：独立 scratch、策略继承、配额、通信经宿主 | §6.4 全绿 | 1 周 |
| **P3** | macOS seatbelt 实现（profile 生成 + 探针） | macOS 上 §6.3 全绿 | 1 周 |
| **P4** | Windows 受限令牌/ACL helper 实现 | §6.3 在 Windows 全绿；`read-only` 标记 `partial` | 2–4 周 |
| **P5** | Unix 家族与边缘：FreeBSD Capsicum、OpenBSD pledge/unveil、边缘 Linux probe 降级 | 各平台 §6.3 子集全绿；`partial` 缺失能力可见；`none` 平台拒绝执行 | 2–3 周 |
| 可选 | Landlock（fork `landlock` 包或 FFI）、gVisor `Strong` 后端 | 单独评估 | 1–2 周 |

**接口冻结纪律**：P0 之后，§5.7 的既有字段与签名不得修改；P1–P4 只允许（a）新增可选字段，（b）新增 `op`/`kind`，（c）提升 `capabilities` 协商项。任何破坏性变更必须升协议 `v` 并保留 v1 解码路径。

P0 与 P1 之间不引入任何 UI 变更；Desktop 的 `SandboxPanel` 在 P1 之后显示真实后端与 `enforcement`。

---

## 8. 风险与未决

| 风险 | 影响 | 缓解 |
|---|---|---|
| Haskell `landlock` 包停更（GHC 9.6） | 无法直接用 Landlock | 先只用 bwrap；需要时 fork 或改用 `psx`/FFI |
| Windows 成本（Win32 + AppContainer） | P4 周期长 | 先交付受限令牌 + ACL（`partial`），或 WSL2 + bwrap |
| 工具链路径（`~/.cabal`、`~/.ghcup`、`node_modules`） | 沙箱内构建失败 | 只读 bind 白名单 + 探针覆盖真实构建 |
| PTY / Chrome / LSP 子进程 | 交互式工具失效 | 分别适配；必要时这些工具走 `Shared` 并显式标注 |
| gVisor 未安装（`runsc` 不在本机） | `Strong` 无法立即验证 | 作为 P4 可选，先做 `Process` 级 |
| 默认断网影响 agent 工作流 | 用户抱怨 | `allowedDomains` + 出口代理；首次使用时提示 |
| FreeBSD / OpenBSD 无 CI 环境 | 后端无法持续验证 | 用 VM（qemu/FreeBSD 镜像）跑探针，或标记 experimental |
| 边缘设备无 Node/Haskell runtime | runner 无法部署 | 静态二进制（C/Rust），或把执行放网关侧 |
| iOS / RTOS 无 OS 沙箱 | 只能拒绝执行 | `Enforcement = None`，UI 明确标注「无沙箱」 |
| Windows 路径语义（junction/ADS/8.3） | 策略可被绕过 | `GetFinalPathNameByHandle` 规范化 + 专项探针 |
| 允许列表只按域名授权 | 可经「已批准域名」外泄（Anthropic 实例，[R10]） | **按能力授权**：session token + API + 方法白名单 |
| 项目级配置在信任前解析 | 克隆仓库即可执行（`.claude/settings.json` 类，[R10]） | 先确认信任，再解析 `./.trha/settings.yaml` |
| 隔离挡住 EDR / 主机监控 | 企业看不到内部行为（[R10]） | `sandbox.jsonl` + 结构化审计导出 |
| 多智能体信任升级 | 子代理输出被默认高信任 | 子代理输出与原始工具输出同等对待，不提升信任级 |

未决问题：

1. 默认策略取 `ReadOnly` 还是 `WorkspaceWrite`？（建议：交互式默认 `WorkspaceWrite`，子代理默认 `ReadOnly`）
2. 工具链只读根的白名单维护方式：静态表 vs 探测（建议：静态表 + 探针测试）。
3. `Strong` 级是否需要支持远端后端（多机）？本版不做。

---

## 9. 参考代码索引

> 正文中的 `[Rn]` / `[Dn]` 指向本表。**仓库根**：R9 为本仓 `/home/yanli/work/trha`；R1–R7 为外部检出（路径以本机为准）；R8/D* 为官方文档。行号为 2026-10-29 建档时，后续可能漂移，定位以符号名为准。

### 9.1 实现代码（R1–R11）

| 编号 | 项目 | 仓库根 | 关键代码 / 配置 |
|---|---|---|---|
| **R1** | codex | `/data/training/cli/codex` | `codex-rs/sandboxing/src/lib.rs`（`SandboxManager` / `SandboxType` / violation）<br>`codex-rs/linux-sandbox/src/lib.rs`（`no_new_privs` + seccomp + bwrap + Landlock）<br>`codex-rs/windows-sandbox-rs/src/lib.rs` + `codex-rs/windows-sandbox-service/src/lib.rs`（受限令牌/AppContainer/MXC）<br>`codex-rs/core/config.schema.json:3446`（`SandboxWorkspaceWrite.writable_roots`、`exclude_slash_tmp`、`exclude_tmpdir_env_var`、`network_access`）<br>`codex-rs/protocol/src/permissions.rs:2230`（`.git` / `.agents` / `.codex` 默认只读）<br>`codex-rs/prompts/templates/permissions/sandbox_mode/{read_only,workspace_write}.md` |
| **R2** | claude-code（ASRT） | `/data/training/cli/claude-code-best/claude-code` | `src/utils/sandbox/sandbox-adapter.ts`（settings → ASRT 适配、`resolveSandboxFilesystemPath`）<br>`src/entrypoints/sandboxTypes.ts:50`（`allowWrite` / `denyWrite` / `denyRead` / `allowRead`）<br>`node_modules/@anthropic-ai/sandbox-runtime/README.md:118`（读 allow-then-deny / 写 allow-only）、`:189`（`denyRead: ['~/.ssh']`） |
| **R3** | deepseek-harness | `/home/yanli/work/deepseek-harness` | `docs/subsystems/sandbox.md`（模式、`enforcement`、`SANDBOX_UNAVAILABLE`）<br>`packages/sandbox/sandbox-local/src/profiles.ts:19,33`（`--tmpfs /tmp`、可写根）<br>`packages/sandbox/sandbox-local/src/index.ts:106`（probe）<br>`packages/sandbox/sandbox-windows-acl/README.md`（受限令牌 + capability SID + Low integrity）<br>`packages/sandbox/sandbox-policy/src/index.ts:47,116,131`（`workspaceRoot` 无 schema 默认） |
| **R4** | DeepSeek-Reasonix | `/home/yanli/work/DeepSeek-Reasonix` | `internal/safety/sandbox/prepare.go:22`（`Prepared` / `PrepareArgs`）<br>`internal/safety/sandbox/seatbelt_darwin.go:27`（`sandbox-exec -p`）<br>`internal/safety/sandbox/protects_other.go:7`（`confinedWriteDirs`）<br>`internal/safety/sandbox/write_roots.go:143`（`planWriteRoots` 链接校验）<br>`SECURITY.md:102`、`docs/SPEC.md:1270`（配置收紧规则） |
| **R5** | qwen-code | `/data/training/cli/qwen-code` | `docs/users/features/sandbox.md`<br>`packages/cli/src/serve/sandbox.ts:71`（6 个内置 profile）、`:237`（默认 `permissive-open`）<br>`packages/cli/src/serve/sandbox-macos-permissive-open.sb`（SBPL 写白名单）<br>`scripts/build_sandbox.js`（容器镜像） |
| **R6** | MiMo-Code | `/data/training/cli/MiMo-Code` | `packages/cli/src/workflow/sandbox.ts:107`（QuickJS `evalScript`）<br>`packages/cli/src/tool/external-directory.ts:102`（`assertWriteAllowed` / `external_directory:ask`）<br>`packages/cli/src/file/protected.ts:6`（TCC / 用户目录保护） |
| **R7** | haskell-agent | `/data/work/functional-programming/hs/haskell-agent` | `packages/agent-server/src/Agent/Server/Sandbox.hs:128`（`protocolVersion = 1`）、`:385`（runner 启动参数）<br>`packages/agent-server/src/Agent/Server/Sandbox/Worker.hs:3`（租户 VM 内 worker）<br>`packages/agent-tools/src/Agent/Tools/IO.hs:540`（macOS Seatbelt profile）<br>`docs/agent-server.md:236`（gVisor / cgroup / 网络策略） |
| **R8** | gVisor | `google/gvisor` | `ADOPTERS.md`（采用者）<br>`g3doc/architecture_guide/platforms.md`（KVM / systrap / ptrace）<br>`g3doc/user_guide/personalities/bwrap.md`（bwrap personality 标志映射与差异）<br><https://gvisor.dev/users/> |
| **R9** | trha 现状 | `/home/yanli/work/trha` | `packages/scheduler/src/Server/toolGuard.ts:17`（`confineWritePath`）<br>`packages/scheduler/src/Permission/permissionRules.ts:83`（`decidePermission`，默认 allow）<br>`packages/scheduler/src/Server/shell.ts:91`（`hardenedEnv`）<br>`src/infra/Infrastructure/Sandbox/Process.hs:28`（`execute`，无隔离）<br>`packages/app/Desktop/src/renderer/ui/SandboxPanel.tsx:6`（占位 UI）<br>`packages/scheduler/src/Subagent/Manager/Manager.ts:61`（`spawn`）<br>`packages/scheduler/src/Server/standardTools.ts:283`（`subagent` 工具）<br>**2026-10-30 补齐（沙箱落地后的实现索引）**：`src/infra/Infrastructure/Sandbox/Runner.hs`（NDJSON 执行循环 + 长驻 stdin）、`Sandbox/Cgroup.hs`（cgroup v2 pids）、`Sandbox/Landlock.hs`（启用状态探测）、`Sandbox/Probe.hs`（三平台探针集合）、`Backend/{Linux,Windows,FreeBSD,OpenBSD}.hs`（平台渲染器）、`packages/sandbox-win-helper/src/{protocol,policy,win32}.rs`（Windows helper） |
| **R10** | Anthropic 安全复盘 | `anthropic.com` | 《How we contain Claude across products》（2026-05-25）：四类事故、三家产品隔离、93% 批准率、0.1%/5–6% 注入成功率<br><https://www.anthropic.com/engineering/how-we-contain-claude> |
| **R11** | Claude Mythos Preview 评估 | `red.anthropic.com` | 《Claude Mythos Preview's cybersecurity capabilities》（浏览器沙箱逃逸、内核提权、FreeBSD NFS RCE；其逃逸 demo 注明测试 harness 未启用浏览器进程沙箱）<br><https://red.anthropic.com/2026/mythos-preview/> |

### 9.2 系统与官方文档（D1–D4）

| 编号 | 主题 | 链接 |
|---|---|---|
| **D1** | FreeBSD Capsicum | <https://man.freebsd.org/cgi/man.cgi?query=capsicum&sektion=4> |
| **D2** | OpenBSD pledge / unveil | <https://man.openbsd.org/pledge.2>、<https://man.openbsd.org/unveil.2> |
| **D3** | Windows AppContainer | <https://learn.microsoft.com/en-us/windows/win32/secauthz/appcontainer-isolation> |
| **D4** | WAMR（边缘/RTOS 的 WASM 兜底） | <https://github.com/bytecodealliance/wasm-micro-runtime> |

### 9.3 内核与协议资料

- Landlock：<https://docs.kernel.org/userspace-api/landlock.html>
- bubblewrap：<https://github.com/containers/bubblewrap>（README 的 Sandbox security / Limitations 两节）
- gVisor 平台与 bwrap personality：[R8]
- AppContainer：[D3]
