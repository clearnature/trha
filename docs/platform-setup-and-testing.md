# 平台开发环境配置与测试指南

> 本文全部内容来自 2026-10～11 的实测记录（Windows 本机 + GitHub CI 的
> Ubuntu/macOS runner），标注 ✅ 的都验证过。改动工具链前先读对应平台的
> 「已知坑」。

---

## Windows（本机实测 ✅）

### 工具链配置

| 工具 | 版本 | 来源 / 备注 |
| --- | --- | --- |
| GHC + cabal | 9.14.1 / 3.16.x | ghcup 安装；`cabal run` 即开发模式（增量编译） |
| GCC | **MSYS2 UCRT64 16.2.0** | `pacman.conf` 里 `IgnorePkg` 锁定；**不要用 winlibs 构建**（AVX2 栈对齐缺陷：同代码 MSYS2 绿、winlibs 段错误） |
| Node | 26.x（≥22.4） | scheduler 引擎要求；Node 26 原生跑 `.ts`（但 `.js→.ts` 导入重映射仍建议走 tsx 或编译后运行） |
| pnpm / tsc | 12.16.x / 7.0.x | 全局安装；tsc 必须是 7.0.x（CI 有版本断言） |
| wgpu-native | v29 Windows 构建 | `3rdparty/wgpu-native/fetch-windows.sh` 下载到 `lib/windows/`；**只保留 `libwgpu_native.dll.a` + `wgpu_native.dll`** |
| cabal.project.local | gitignored | `extra-lib-dirs: <绝对路径>/3rdparty/wgpu-native/lib/windows`（configure 期 wgpu 检查需要） |

### 已知坑（全部实测踩过）

1. **控制台编码**：先 `chcp 65001`，否则 TUI/测试在输出 Unicode（`↔`）时
   `commitBuffer: invalid character` 直接死。
2. **OpenMP**：GHC 自带 mingw 没有 `omp.h`；`trha.cabal` 已条件化
   （`#ifdef _OPENMP`），Windows 段不开 `-fopenmp` 即可编译。要开的话从
   MSYS2 拷 `omp.h` + `libgomp` 到 GHC 的 mingw。
3. **28433 是 HTTPS**：`~/.trha` 下有 TLS 证书时 `startServer` 自动升
   HTTPS——测试用 `curl -k https://127.0.0.1:28433/...`，别用 `http://`
   （`Empty reply` 会误导）。
4. **文件锁**：杀软/索引器锁 `.tmp` 与 json，rename 报 EPERM/EBUSY——
   `stateStore.ts` 已有退避重试；测试清理目录失败（EBUSY rmdir）时重跑即过。

### 构建 / 测试

```bat
cabal build all                        :: 全量（含 webgpu）
cabal test trha-sandbox-test           :: 沙箱 53 例
cabal test trha-webgpu-test            :: GPU 探针（本机独显 ✓）
cabal test trha-test                   :: ⚠️ Windows 已知差异见下
cd packages\scheduler && npx vitest run test\agent-tools.test.ts   :: 本地复现 ts 失败
```

`trha-test` 在 Windows 的已知差异（Ubuntu 全绿 988 例）：
`StreamTimeoutSpec` 首字节超时不触发（in-process warp 的 socket 行为差异）、
`trha-cli-test` 卡住。CI 以 Ubuntu 结果为准。

### 沙箱验收探针（真机）

```bat
ghc -isrc/infra -o probe1.exe test\manual\AppContainerIsolation.hs && probe1.exe
:: 期望：write workspace -> 0 / write C:\Windows -> 1 / rmdir workspace -> 1

ghc -isrc/infra -o probe2.exe test\manual\PathIsolation.hs && probe2.exe
:: 期望：PATH-ISOLATION: PASS（junction 逃逸拒收 / 正常放行 / fail-closed）
```

### 三进程开发栈（kernel + scheduler + TUI 壳，三个终端）

```bat
:: 终端 1 — kernel（Haskell）
cd packages\app\CLI
cabal run trha -- serve --kernel-port 19433

:: 终端 2 — scheduler（TS；二选一）
cd packages\scheduler
npx tsx src/cli.ts                     :: 开发最快
npm run build && node dist\cli.js      :: 经典（与 CI 一致）

:: 终端 3 — TUI 壳（Haskell）
cd packages\app\CLI
cabal run trha
```

环境变量默认值已对齐：kernel 19433 ← scheduler（`TRHA_LLM_PORT`）→
TUI（`TRHA_PORT`=28433、`TRHA_TOKEN`=dev-token）。
端到端验证：`curl -k -X POST https://127.0.0.1:28433/api/agent/step ...`
（kernel 无 LLM key 时走 stub 模型，回复带 `[stub]` 前缀属正常）。

---

## Ubuntu（CI 实测 ✅，hs-linux workflow 同款脚本）

### 工具链配置

```bash
curl -sSLo /tmp/ghcup https://github.com/haskell/ghcup-hs/releases/download/v0.2.6.2/x86_64-linux-ghcup-0.2.6.2
chmod +x /tmp/ghcup
/tmp/ghcup install ghc 9.14.1 && /tmp/ghcup install cabal 3.16.1.0
/tmp/ghcup set ghc 9.14.1 && /tmp/ghcup set cabal 3.16.1.0
echo "$HOME/.ghcup/bin" >> "$GITHUB_PATH"     # 本机：export PATH 即可
```

或直接用 `haskell-actions/setup@v2`——**必须加 `cabal-update: false`**：
action 的隐式 `cabal update` 会读本目录 `cabal.project`（`../math` 不存在）
直接失败（hs-linux.yml 已配置）。

### 构建 / 测试

```bash
# CI 用 cabal.project.ci（math 检出到 .ci/math）；本机直接 cabal.project
cabal update --project-file=cabal.project.ci
cabal build --project-file=cabal.project.ci all
cabal test  --project-file=cabal.project.ci all   # 988 例全绿 ✅
cd packages/scheduler && npm ci && npx vitest run  # 见「已知」time-context 修复后剩 2 例
```

沙箱探针：Linux 用 **bubblewrap**（`sbp`/bwrap 路线，ubu17 分支合入的实现在
`Backend/Linux.hs`），`trha-sandbox-test` 内含 Linux 用例。

---

## macOS（CI 配置 ✅；Seatbelt 真机探针已入库，等 runner 触发）

### 工具链配置

```bash
# runner 钉 macos-15（macos-latest 的 SDK 27 有 tapi error，GHC 9.14.1 链接器拒绝）
curl -sSLo /tmp/ghcup https://github.com/haskell/ghcup-hs/releases/download/v0.2.6.2/aarch64-apple-darwin-ghcup-0.2.6.2
chmod +x /tmp/ghcup
/tmp/ghcup install ghc 9.14.1 && /tmp/ghcup install cabal 3.16.1.0
/tmp/ghcup set ghc 9.14.1 && /tmp/ghcup set cabal 3.16.1.0
```

（`sandbox-macos.yml` 同款，含 ghcup/依赖缓存的 always 保存——失败也留缓存。）

### 测试

```bash
cabal update --project-file=cabal.project.ci
cabal build --project-file=cabal.project.ci trha-infra
cabal test  --project-file=cabal.project.ci trha-sandbox-test
# Linux-only 用例在 macOS 上 pending 属预期（步骤名已标注）
```

### Seatbelt 真机探针

```bash
ghc -isrc/infra -o macprobe test/manual/MacIsolation.hs && ./macprobe
# 期望：write-workspace 成功 / write-outside($HOME) 拒收 / network-off 拒收
# 最后输出 MAC-ISOLATION: PASS
```

profile 由 `sbplProfile` 生成（SBPL 首条匹配优先：allow 必须先于 blanket
deny；`sandbox-exec` 没有 `--` 分隔符）。已接入 `sandbox-macos.yml`
（Seatbelt isolation probes 步骤，grep `MAC-ISOLATION: PASS` 判定）。

### 已知坑

1. `/proc/self/uid_map` 不存在——`ConfigSpec.hs` 已容错（读不到按 host
   映射处理，另两个信号 guestEnv/HOME 在 macOS 仍有效）。
2. Apple 只认自家工具链：发布产物在 macOS runner 上原生构建 + 签名，
   osxcross 交叉产物仅供本地开发。

---

## 三平台的通用约定

| 项 | 值 |
| --- | --- |
| kernel 端口 | 19433（`trha serve --kernel-port`） |
| scheduler 端口 | 28433，**有证书即 HTTPS**（`resolveTls`） |
| 握手 token | `dev-token`（仅 loopback；非 loopback + 默认 token 会被 startServer 拒绝） |
| 会话持久化 | `~/.trha/scheduler-state`（`TRHA_STATE_DIR` 覆盖） |
| 运行时发布 | `~/.trha/runtime.json`（`writeRuntimeSection`） |
| 沙箱探针源码 | `test/manual/{AppContainerIsolation,PathIsolation,MacIsolation}.hs` |
| CI 分工 | `hs-linux.yml` / `sandbox-windows.yml` / `sandbox-macos.yml` / `ts-linux.yml` / `ts-windows.yml`（CI.yml 只留聚合与 Node 系） |
