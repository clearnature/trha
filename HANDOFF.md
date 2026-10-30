# HANDOFF — sandbox 交付

> 快照时间：2026-10-30。依据 `docs/plans/sandbox-delivery-plan.md`（里程碑是门禁，不是日期承诺）。
> 本文只记「现在在哪、下一步做什么、什么被什么挡住」，细节看计划与 ADR。

## 1. 进度快照

| 里程碑 | 状态 | 说明 |
|---|---|---|
| **M0** 接口冻结 | ✅ | `Policy`/`Scope`/`Plan`/`Backend`/`Protocol` 全部落地，`cabal build all` 绿 |
| **M1** Linux 进程级 | ✅ | bwrap 渲染、runner（NDJSON + 长驻 stdin）、探针、审计、UI/CLI/TUI、执行点接入（bash / run_code / terminal / terminal_open / pwsh）、Landlock **探测**；**2026-10-30 修复**：`sandbox.yaml` 的 limits/readonlyRoots/envAllow 接线（ADR-011）、凭据目录 tmpfs（ADR-012）、XDG 注入让沙箱内能用宿主 cabal store、`status --json` 的 capabilities/platform 用真实 probe |
| **M2** 多智能体作用域 | ✅ | Scope 树、独立 scratch、命名空间隔离探针、实验批（变体×种子/重试/`repro.json`）、cgroup v2 pids 配额（ADR-010） |
| **M3** macOS | 🟡 实现完成、**零真机验证** | SBPL 渲染器 + `SandboxMacSpec` + `sandbox-macos.yml` 都在；CI 额度为 0，从未在真 macOS 上跑过 |
| **M4** Windows | 🟡 可无平台推进的部分已完成 | helper（Rust）21+28 单测、Job Object、路径规范化、受限令牌**已接线**（read-only 生效）、渲染器与探针集合；**真机未验证** |
| **M5** Unix / 边缘 | 🟡 | FreeBSD/OpenBSD 渲染器 + launcher 骨架、边缘降级（bwrap 不可 unshare → Partial）、§9 索引核对；**真机与 qemu 未做** |

测试现状：`cabal test trha-sandbox-test` → **84 examples / 0 failures / 1 pending**（pending 是 macOS-only）；
`cargo test`（helper）→ **28 passed**；launcher `make check` → **9 项契约 smoke 全绿**；
scheduler `vitest` 相关文件 → 60 passed。

## 2. 关键实现位置

| 关注点 | 文件 |
|---|---|
| 策略 / Scope / 计划 | `src/infra/Infrastructure/Sandbox/{Policy,Scope,Plan,Backend}.hs` |
| 执行循环（NDJSON、长驻 stdin、cgroup、审计） | `src/infra/Infrastructure/Sandbox/Runner.hs` |
| 平台渲染器 | `Sandbox/Backend/{Linux,Windows,FreeBSD,OpenBSD}.hs` |
| 探测 | `Sandbox/Probe.hs`、`Sandbox/Landlock.hs`、`Sandbox/Cgroup.hs` |
| scheduler 侧 seam 与会话 | `packages/scheduler/src/Server/{sandbox,extraTools}.ts` |
| Windows helper（Rust） | `packages/sandbox-win-helper/src/{protocol,policy,win,win32,winargs,path}.rs` |
| BSD launcher（C） | `packages/sandbox-bsd-launcher/launcher.c` |
| 决策记录 | `docs/plans/sandbox-decisions.md`（ADR-001…010） |

## 3. 下一步（按「能否在无真机下推进」排序）

1. **T4.6 真机探针**（需要一台 Windows 10/11）：把 `windowsProbes` 跑一遍，
   `write-system` / `read-user-secret` / `junction-escape` 必须失败，
   `write-workspace` 在 workspace-write 下必须成功。全绿后才有资格把
   `enforcement` 从 `Partial` 往上抬。
2. **M3 真机验证**（需要 CI 额度或一台 macOS）：`sandbox-macos.yml` 手动触发一次，
   看 `SandboxMacSpec` 是否真绿（2026-10-29 的 SBPL 顺序修复从未在真机验证）。
3. **T5.4 qemu VM CI**（需要虚拟化环境）：FreeBSD/OpenBSD 各一台，
   跑 `make check` + 真机 launcher 探针。
4. **workspace-write 的 restricting SID + ACE 组合**（需要 Windows）：代码已接线
   （`grant_directory_write` 授权 → 以当前用户 SID 为 restricting SID 建令牌），
   但 ACE 顺序、继承标志与 `WRITE_RESTRICTED` 的实际效果必须在真机确认；
   Haskell 侧 `windowsCaps` 的 `Partial` 也要跟着改。
5. **T4.7 签名分发**（需要 Windows 代码签名证书）、**T4.8 AppContainer**（可选，5 人日）。

## 4. 未决 / 需要拍板

| 项 | 现状 | 需要谁 |
|---|---|---|
| Windows `enforcement` 何时抬到 `Full` | 现在 read-only 也报 `Partial`（限制写、不限制读） | 真机探针结果 |
| 是否给 Landlock 上 launcher | 现在只探测不强制（`Sandbox/Landlock.hs`） | 用户：可选增强，需额外 launcher |
| 按域名的网络 ACL | `NetworkAllow` = `--share-net` 全放行，`domains` 只进审计（ADR-009） | 用户：要不要做代理桥 |
| FreeBSD capsicum 的 fd 传递约定 | launcher 把预开目录 fd 留在子进程，编号约定未定 | 真机 |
| CI 额度 | `clearnature/trha` 私有库 Actions 分钟耗尽，所有 run `steps=0` | 用户（billing） |

## 5. 已知坑（别再踩）

- `cabal build exe:trha` 会因 `trha` 与 `trha-cli` 同名而**静默失败**（Cabal-7132），
  必须用 `cabal build trha:exe:trha`。曾因此让端到端探针跑了半小时的旧二进制。
- cabal ≥3.10 用 XDG 目录：store 在 `~/.local/state/cabal/store`、索引在
  `~/.cache/cabal/packages`；CI 里缓存 `~/.cabal/*` 是无效的（已修）。
- `terminal_open` 在沙箱里是「管道 + 常驻 shell」，**不是真 PTY**：
  `terminal_signal` 会终止整个会话而不是只给前台进程发信号。
- Windows helper 的 `WRITE_RESTRICTED` 且不给 restricting SID ⇒ 写全拒；
  workspace-write 需要的组合尚未在真机验证。
- **只读根必须 `--ro-bind-try`**：`readonlyRoots` 里有宿主不存在的路径（本机 `/nix/store`）
  时，严格 `--ro-bind` 会让 bwrap 直接退出，**沙箱整体不可用**（2026-10-30 踩过，
  连 agent 自己的 shell 都起不来）。writable 根仍用严格 `--bind`。
- **沙箱内不能再起沙箱**：bwrap 在已有 user namespace 里建新命名空间会被
  AppArmor/内核拒绝（`No permissions to create a new namespace`）。Linux/runner 集成
  spec 因此在本机变成 `pending`（`withFullBwrap` / `requireBwrap` 判 `bcEnforcement`），
  真绿只能在宿主直接跑 `cabal test trha-sandbox-test`。
- **HOME 被改成 scratch，工具链靠 XDG 注入**：渲染器把宿主 HOME 转成
  `XDG_STATE_HOME`/`XDG_CONFIG_HOME`/`XDG_DATA_HOME`（只读）与写 scratch 的
  `XDG_CACHE_HOME`。cabal 仍会用 `getpwuid` 写 `~/.cache/cabal/logs`，只读时打印
  `withFile: permission denied` 警告（不影响退出码）。
- **`limits.memoryMiB > 0` 真的会限制构建**：`RLIMIT_AS` 是虚拟内存，2 GiB 能把
  GHC 编译逼死；默认 0（ADR-008）。要在沙箱里编译大项目，先把它设 0。
- **嵌套宿主上 `sandbox status` 报 `Partial`** 是预期的（probe 跑不了 `--unshare-all`），
  不代表后端坏；看 notes 里的原因。
- **systemd-run 的可用性在 runner 启动时探测一次**：pids 限制首选
  `systemd-run --user --scope`，它要连 user manager 的 D-Bus。scheduler 从
  cron/裸 tmux/ssh 启动时没有 `XDG_RUNTIME_DIR`，探测会失败（现象：
  `Failed to connect to user scope bus`）。失败后该 runner 的整个生命周期都
  降级为「spawn 后写 `cgroup.procs`」——命令照常执行，不再因此失败，代价是
  pids 上限存在毫秒级竞态（fork 可能在入组之前发生）。
  要覆盖「运行中 D-Bus 抖动」，需要每次 exec 重探，但 `systemd-run --scope`
  本身有数百毫秒开销，不划算；容器/无 systemd 环境本就走这条降级路径。
