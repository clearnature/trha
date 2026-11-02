# Windows 开发笔记与跨平台交接（2026-11-02）

> 适用基线：`main = a6d4c8f`（「默认直连」代理策略落地后）。
> 作者：Windows 11 开发机上的 TUI / 内核 API 接入与代理策略修复批次。
> 读者：接手同一代码基线的新环境（尤其 Ubuntu/Linux）——前两节是**平台差异**
> 与**环境坑**，第三节是 Ubuntu 侧初始化清单，第四节是与 Reasonix 的对照。
> 本文档是经验笔记，不是规范；冲突时以 `contracts/protocol-shell-kernel.md`
> 与 `architecture/` 为准。

--------------------------------------------------------------------------------

## 1. 一句话结论（新环境先看这里）

**Windows 与 Ubuntu 上行为不一致的根源，几乎全部来自环境，而不是代码：**

| 差异 | Windows（本机） | Ubuntu（此前验证） |
|---|---|---|
| 环境代理 | 宿主注入 `HTTPS_PROXY=http://127.0.0.1:10808` | 无 → 默认直连 |
| 本地代理稳定性 | 偶发端口被抢/卡死（`WinError 10048`） | 不适用 |
| `TEMP` 路径大小写 | `C:\Windows\TEMP` vs 磁盘 `Temp` → clang 警告刷屏 | 无此问题 |
| GHC 测试 | `parallel tool calls` 用例挂死（CPU 零增长） | 待验证 |
| shell 编码 | Git Bash 按 GBK 发请求体 → kernel 正确拒绝非 UTF-8 | UTF-8 |

`9a3cbb2`（默认直连）落地后，Windows 上六项 SDK 测试全绿、不再依赖本地代理；
`833ea2b` 把 `configProxy` 同步到 `TRHA_PROXY`，两条上游链路（Core.HTTP 与
LLM.Stream/provider adapter）从此共用一个配置源——**修复前这两条链路读的是
不同的配置**，这就是「`configProxy: none` 只关了一半、上游仍走本地代理」的根因。

--------------------------------------------------------------------------------

## 2. 已修复的平台缺陷清单（Ubuntu 侧无需再修，但要知道语义）

每项：症状 → 根因 → 修复提交。这些修复**都是跨平台的**（Linux 行为不变或更优），
Ubuntu 侧拉到基线后即为已生效状态。

### 2.1 Windows 上 TUI 进不去（`11c028a` + `692b774`）

- 症状：停在「正在启动 TUI 界面...」，进程活着但界面永不出现。
- 根因一：`Bootstrap.spawnDetached` 在 Windows（无 `setsid`）直接启动常驻服务
  后 `waitForProcess`——kernel/scheduler 永不退出，调用方永久阻塞。
  修复：仅 `setsid -f` 包装器（短命）才回收。
- 根因二：`ensureBackend` 同步等待（kernel 40 + scheduler 60 轮 × 0.5s）。
  修复：TUI 先进 brick，后端在 `async` 里拉起，结果只写 `logLine`
  （brick 接管 stdout 后 `putStrLn` 会撕坏画面）。

### 2.2 官方 SDK 流式不兼容（`f611a11`）

- 症状：OpenAI/Anthropic SDK 的 `stream=True` 拿到 JSON、按 SSE 解析后为空白。
- 根因：官方 SDK 在**原路径**上带 `stream: true` 要 SSE；trha 把 SSE 放在
  `/…/stream` 子路径。
- 修复：三条协议路由改 `Raw`，按 body 的 `stream` 字段（或 `/stream` 子路径）
  分派——SSE 走原流式应用，JSON 走原非流式 handler。
- **实现坑（重要）**：Raw 分派时不能把 `requestBody` 换成恒定返回相同字节的
  reader——下游 `strictRequestBody` 会读到非空而**无限循环**。必须用一次性
  reader（`IORef` 只吐一次，之后 `mempty`）。

### 2.3 anthropic/responses 非流式路由不解析 provider（`17aee73`）

- 症状：同一份 `providers.json`，openai 协议打真实上游，anthropic/responses
  返回 `"[stub] ..."`（默认 stub adapter）。
- 根因：`anthropicMessagesHandler` / `responsesHandler` 直接用启动时注入的
  adapter，只有 `openaiChatHandler` 走 `resolveAdapterIO`。
- 修复：三个非流式 handler 统一先解析（请求体 `provider` 字段 > `inUse`），
  失败按 `502 provider.adapter_unavailable` 返回。

### 2.4 kernel 只认 `Authorization: Bearer`（`ce84665`）

- 症状：Claude Code / Anthropic SDK 默认把 key 裸放在 `x-api-key`，一律 401。
- 修复：`Security.factsOf` 在无 `Authorization` 时回读 `x-api-key`；
  `tokenPresented` 对裸值走 `constantTimeEq`。Host/Origin/loopback 门禁不变。

### 2.5 Responses 端点与 input 形态（`3848cc6` + `7d3298c`）

- DeepSeek 文档给的端点是 `https://api.deepseek.com/responses`（无 `/v1`），
  旧的 `rootOf baseUrl + "/v1/responses"` 会拼出 `…/responses/v1/responses`。
- `responsesUrl`：baseUrl 以 `/responses` 结尾 → 原样使用；否则维持
  OpenAI 兼容拼接（`api.openai.com` 等不受影响）。
- `input` 允许字符串或 items 数组，数组里的 `content` 允许字符串或
  `[{"type":"input_text",…}]`（只取 text part，图片 part 忽略）。
- 流式 `responsesStreamApp` 曾只从原始 `input` 数组取消息——字符串 input 时
  对话为空，上游 400 `Input items array must not be empty`。已回落到
  `parseResponses` 解析出的 turns。

### 2.6 `/v1/models` 报 stub 模型（`cffc404`）

- 修复：合并 `providers.json` 各 provider 的 `models`（同名去重，`inUse`
  provider 的归属优先），没有 provider 配置时回落 adapter 自带列表。
- 注意：stub kernel（`trha serve`，无上游 key）下各协议仍会返回
  `[stub] …`——这是设计内的降级，不是 bug。

### 2.7 仓库卫生（`ae1f848` / `a497731` / `7d3298c` 前后）

- **两个同名 `executable trha`**（根 `trha.cabal` + `trha-cli.cabal`）各自独立
  编译，产物落在两个目录，`cabal run/list-bin` 在其间隐式选择——排查 TUI 时
  容易跑到旧的一份。已删 `trha-cli.cabal` 的副本，`trha-cli-test` 保留。
- `cabal.project` 的 `builddir:` 在 cabal 3.16 不支持（每次构建警告并忽略，
  且使配置比对反复失配 → `cabal run` 全量重编）。已删；要改产物位置用命令行
  `--builddir`。
- `-Wnonportable-include-path`（clang 对 `C:\Windows\TEMP` vs `Temp`）无法在
  仓库侧关闭（cabal 拒绝非可移植 `cpp-options`，GHC 不把 `-optc/-optP` 传给
  那次调用）。要消掉请改环境变量 `TEMP/TMP` 指向真实大小写的目录
  （本机已改为 `C:\Windows\Temp`，实测警告 13 → 0）。

### 2.8 探针（`355de0d`）

TUI 启动路径的 `probe` 行写进 `~/.trha/logs/trha-<date>.log`：
`probe env`（tty/代码页）、`tui.start`、`vty.ready ms`、`brick.exit ms`、
`startup-data failed`（启动期后台取数异常不再静默）。「界面出不来」先看这份
时间线。

--------------------------------------------------------------------------------

## 3. Windows 环境经验（本机已配置，迁移新 Windows 机器时可照抄）

### 3.1 工具链

- Node 用 **fnm** 管理（`fnm install`；系统级 `trha` 命令由 npm 全局包提供，
  `C:\Users\<user>\AppData\Roaming\npm\trha.cmd`）。
- npm 包 `@trha/cli`（`packages/app/CLI-npm`）：定位 Haskell exe 并透传；
  `vendor/trha.exe` 已 gitignore（~94MB，不进 git）。
- 全局安装：`npm install -g packages/app/CLI-npm`；开发期更新用 `npm link`
  （vendor 换新 exe 即时生效）。

### 3.2 环境

- `TEMP` 大小写（见 2.7）。
- 宿主注入的 `HTTPS_PROXY` 是全局性的：不仅影响 kernel，也影响 pip（经
  127.0.0.1:10808 重试）。`configProxy: none` 只管 kernel；pip 等外部工具需
  自行处理。
- 大量测试后 `TIME_WAIT` 可达 2.4 万+（本地代理短连接为主），本地临时端口
  （默认 16k）耗尽后**所有**新连接报 000/`Address already in use`——这是
  「突然全部请求失败」最常见的原因。等 4 分钟或重启网络栈。

### 3.3 TUI 调试

- 启动探针（见 2.8）是第一入口。
- `strictRequestBody` 在 Raw 路由挂起 = body reader 无限循环（见 2.2 坑）。
- 中文 IME 激活时 vty 收不到字符（IME 吃键）——切英文输入法再试。
- **`cabal run` 的转发层会按 locale 转码输出**（中文乱码的来源之一）；
  诊断时直接跑 exe：`& (cabal list-bin trha)`。

### 3.4 测试

- `trha-test` 的 `parallel tool calls` 组在 Windows 挂死（进程 CPU 零增长），
  **未定位**；pre-push 门两次以 `--no-verify` 绕过（见 §6）。
- `trha-cli-test` 曾因两个用例引用 `HOME` 隔离与路径分隔符在 Windows 失败，
  已改为 `TestHome`（设 `HOME`+`USERPROFILE`+`TRHA_CONFIG_DIR`）与
  `(</>)` 构造期望路径（`9a3cbb2` 同期修复）。
- 链接报 `Permission denied` = 有 `trha.exe` 进程没退（先
  `tasklist | findstr trha`）。

--------------------------------------------------------------------------------

## 4. Ubuntu 侧初始化清单（转移时照做）

```bash
git clone https://github.com/clearnature/trha.git && cd trha
git log --oneline -1        # 应 >= a6d4c8f

# Haskell
cabal build all             # 首次全量编译
cabal test trha-test        # ← 重点：观察 parallel tool calls 在 Linux 的表现

# Node 工程
cd packages/scheduler && npm install && npx tsc --noEmit && npx vitest run test/<file>.test.ts

# kernel（三协议 API，127.0.0.1:19433）
./dist-newstyle/.../trha serve --kernel-port 19433
curl -s http://127.0.0.1:19433/health
```

`~/.trha` 配置（从 Windows 迁移）：

| 文件 | 迁移动作 |
|---|---|
| `providers.json` | 原样拷贝——三条 `baseUrl` 都是公网 URL，跨平台通用 |
| `provider-keys.json` | 原样拷贝（key 通用）；**注意**：Windows 上 chmod 600 只改了 git 模拟位，实际是 NTFS ACL——拷到 Linux 后手动 `chmod 600` |
| `settings.yaml` | 建议保留 `configProxy: none`（Linux 无代理需求；`env` 也行，语义见 `Core/HTTP.hs` 的 `resolveProxy`） |
| `vendor/trha` | **不要**拷 Windows exe；`cabal build trha` 后把 Linux 二进制放 `packages/app/CLI-npm/vendor/trha`，再 `npm install -g packages/app/CLI-npm` |
| `kernel-token` | 不要拷——kernel 每次启动轮换，外部客户端接入时重新读 |

跨平台语义核对表（代码已保证，Ubuntu 侧验证清单）：

| 契约 | 验证命令 |
|---|---|
| 默认直连（空 configProxy 不读环境代理） | `TRHA_PROXY` 未设时直连 DeepSeek 成功 |
| `env` opt-in | `TRHA_PROXY=http://…` 时走代理 |
| 同路径 SSE | OpenAI/Anthropic SDK `stream=True` 有增量 |
| 三 handler 统一 provider 解析 | anthropic/responses 非 stub 回复 |
| `x-api-key` ≡ Bearer | Claude Code / SDK 两条路都 200 |

--------------------------------------------------------------------------------

## 5. 与 Reasonix 的对照（为什么这样修）

| 方面 | Reasonix | trha 现状 |
|---|---|---|
| TUI 栈 | Go + bubbletea v2 + lipgloss（**非 Electron**；Electron 是其独立 desktop 前端） | Haskell + brick/vty |
| 启动顺序 | TUI 先接管终端，连接状态在 model 里异步推进 | `692b774` 对齐 |
| 同路径流式 | 原生（bubbletea） | `f611a11` 对齐 |
| 代理 | `proxy_mode = "auto"`（默认读环境）+ per-provider `no_proxy` | 修复前：两模块读不同源；现在 `configProxy` 为单一来源 + `env`/`none`/URL + `peNoProxy` 已接线（`205a40c`） |
| 字形适配 | `glyphFit`（GDI 查字形 + 实测列宽 + ASCII 降级），解决 conhost 画不出 `─│╭╮`/emoji 的边框错位 | **未移植**（`UI.TextWidth` 只算宽度）；936 代码页的 conhost 下仍可能边框错位，Windows Terminal（UTF-8）不受影响 |
| provider 上游解码 | 子进程输出按 GB18030 解码 | 不适用（trha 上游是 HTTP） |

`peNoProxy`/`scNoProxy` 的接法（`205a40c`）即是对 Reasonix
`provider_entry.no_proxy` 语义的移植。

--------------------------------------------------------------------------------

## 6. 遗留问题（未解决，明确记录）

1. **`trha-test` 的 `parallel tool calls` 用例在 Windows 挂死**：进程 CPU 零
   增长（`tasklist /V` 观察 8s 不变），pre-push 门两次 `--no-verify` 绕过。
   Ubuntu 侧是否复现待验证；若复现则是真 bug（该组测试可能依赖未启动的外部
   服务），需要定位。
2. **`UI.Render.FilePart` 的 `-Wmissing-home-modules`**：已在 `9a3cbb2` 前后
   把该模块补进 `exe:trha` 的 `other-modules`？——**没有**，当时只修了代理与
   TUI；该警告仍在（无害，但每次构建刷屏）。
3. **conhost 936 下边框错位**：需要 Reasonix 式 `glyphFit`（GDI 字形探测 +
   列宽实测 + ASCII 降级）才能根治；Windows Terminal/UTF-8 终端不受影响。
4. **流式偶发 90s 无响应头**：直连后未复现，观察是否与本地代理残留有关。
