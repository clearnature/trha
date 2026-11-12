# Electron 44 升级：变更与待办

> 状态（**2026-09-17 更新**）：**依赖 + 二进制 + 打包链路 + 实机启动 均已验证**。
> linux `.deb` 产出成功且契约自检通过；打包产物实机启动、随包 scheduler `/health` 返回 200。
> 启动仍需 `--no-sandbox`（或 sudo 设 `chrome-sandbox` 为 root:4755）—— 见 §3.1。
> 本轮另外发现并修复了**两处 electron-builder 26 的破坏性变更**，见 §6。
> 时间：2026-09-15 · 分支 `main` · 改动**尚未提交**

## 1. 变更内容

| 文件 | 改动 |
| --- | --- |
| `packages/app/Desktop/package.json` | `electron`: `^28.0.0` → **`44.2.0`**（精确锁定） |
| 同上 | `electron-builder`: `^24.13.3` → **`^26.15.3`** |
| `packages/app/Desktop/package-lock.json` | 随之更新（electron `44.2.0` / electron-builder `26.15.3`） |

动因：与 `DeepSeek-Reasonix`（`44.2.0`）、`DeepSeek-Reasonix-studio-v2.13.0`（`44.1.0`）的 electron 线对齐。这两个较新的项目都采用**精确锁定**，而 trha 原先停在 `^28.0.0`（范围，易漂移）。

## 2. 已验证的部分

| 检查项 | 结果 |
| --- | --- |
| `node_modules/electron` 版本 | `44.2.0` |
| 二进制 `dist/` | 283 MB，`path.txt` = `electron` |
| 二进制可执行 | `electron --no-sandbox --version` → `v44.2.0` |
| 现有测试 | `vitest`：30 files / **137 passed, 6 skipped** |
| `npm run build:main`（tsc） | EXIT=0 |
| `npm run build:renderer`（vite） | EXIT=0，75 modules |
| `npm run package`（含 sync + electron-builder 26.15.3） | **EXIT=0**，产出 `release/trha_0.1.0_amd64.deb`（128M） |
| 产物契约 | `node scripts/verify-artifact.mjs …` → **CONTRACT OK: trha 0.1.0 amd64**（回执 `r-mu52cxfw-jnesjs`） |
| **实机启动**（打包产物，`--no-sandbox`） | **✅ 已做**：`[scheduler] Scheduler listening on port 3456` · `Tools: 59 registered` · `[studio] kernel 0.0.0-dev`；`curl /health` → **HTTP 200** `{"status":"ok","version":"0.1.0","modes":[…]}`（回执 `r-mu52how8-ei0sg7`） |
| 负向控制（不带 `--no-sandbox`） | **✅ 红在正确的地方**：exit 133，`FATAL … SUID sandbox helper binary … chrome-sandbox`（回执 `r-mu52huhe-m9ivzy`） |

**主进程 / preload 的人工检查**（`src/main/index.ts` 215 行、`src/preload/index.ts` 12 行）：
用到的 electron API 为 `app`、`BrowserWindow`、`ipcMain`、`contextBridge`、`ipcRenderer`、
`process.resourcesPath`；配置为 `contextIsolation: true` + `nodeIntegration: false` +
`sandbox: true`（最保守组合）。
**未发现 28→44 期间被移除或改签名的 API。**

### 2.1 测试覆盖的边界（重要）

`vitest` 全部跑在 **jsdom** 下，**不加载 electron 运行时**，因此 `src/main/` 与
`src/preload/` 一行都没有被覆盖。这批测试通过是必要条件，**不是** 28→44 兼容性的证明。

## 3. 待处理（后期再处理）

### 3.1 `chrome-sandbox` 的 SUID 权限 —— 当前唯一的启动阻塞

```
FATAL: The SUID sandbox helper binary was found, but is not configured correctly.
You need to make sure that .../node_modules/electron/dist/chrome-sandbox
is owned by root and has mode 4755.
```

现状：`chrome-sandbox` 权限为 `-rwxr-xr-x yanli yanli`；本机**无免密 sudo**，无法自动修复。

```bash
# 方案 A（标准做法，需输入密码）
sudo chown root:root node_modules/electron/dist/chrome-sandbox
sudo chmod 4755 node_modules/electron/dist/chrome-sandbox

# 方案 B（开发期绕过，不动系统权限）
ELECTRON_DISABLE_SANDBOX=1 npm start
```

注：这是 electron 在 Linux 上的**固有要求**，不是本次升级引入的问题。

### 3.2 实机启动验证（**✅ 2026-09-17 已做** —— 下面保留原始步骤与观察点）

> **实测结论**：用 `./release/linux-unpacked/trha --no-sandbox` 启动，主进程起来、
> 随包 scheduler 在 3456 上服务、`/health` 返回 200（`r-mu52how8-ei0sg7`）。
> **仍未验证**：GUI 是否真的渲染出窗口（本机无法截图观察；日志只证明主进程 + scheduler + HTTP 健康）。
> 终止时日志尾部的 `GPU process isn't usable` / `Network service crashed` 是 **SIGTERM 拆栈产物**（发生在健康之后），不是启动失败。

测试覆盖不到主进程，必须实机跑一次：

```bash
cd packages/app/Desktop
npm run dev     # tsc watch + vite
npm start       # electron .
```

重点观察：主进程启动是否报错、preload 的 `contextBridge` 是否暴露成功、
`ipcMain.handle` 各通道（`get-token` / `get-scheduler-port` / `get-app-version` /
`get-studio-info` / `get-prefs` / `set-prefs`）是否可达，以及 scheduler 握手是否在 5s 内完成。

### 3.3 electron 二进制镜像未配置（会静默复发）

本次 `npm install` **实际没有装上 electron**：`node_modules/electron/` 里只有包元数据，
无 `dist/`、无 `path.txt`。

根因：`registry` 指向 `registry.npmmirror.com`，但 **`electron_mirror` 未配置**，
于是 `install.js` 越过 npm 镜像、去 GitHub Releases 直连下载二进制——而本机直连 GitHub
会 TLS 断流。（`~/.cache/electron/` 里只有 `electron-v28.3.3-linux-x64.zip`，没有 44 的，
可作佐证。）

已用下面这条补下载成功：

```bash
ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/ node node_modules/electron/install.js
```

**建议**在 `packages/app/Desktop/.npmrc`（**项目级**，不要写进 `~/.npmrc`）加入：

```
electron_mirror=https://npmmirror.com/mirrors/electron/
```

否则下次 `npm install`、CI 或换机器时会重现「看起来装好了、其实起不来」。

### 3.4 改动尚未提交

`git status` 显示 `packages/app/Desktop/package.json` 与 `package-lock.json` 为已修改未提交。
建议与 §3.2 的实机验证结果一起提交。

## 4. 已知风险 / 待观察

| 项 | 说明 |
| --- | --- |
| `@types/node` 版本错位 | 项目声明 `^20.0.0`，electron 44 自带 `@types/node ^24.9.0`。目前靠 `skipLibCheck: true` 兜底，未发现问题；若出现类型冲突需统一 |
| electron-builder 24 → 26 | ~~跨 2 个主版本，配置项可能报未知字段；打包链路完全未验证~~ → **✅ 已验证，且**真的**踩了两个破坏性变更**（见 §6） |
| 打包时的 node runtime | `scripts/sync:node` 会把**本机 Node（v24）** 拷进 `resources/node-runtime/`，与 electron 44 内置 Node 不是同一个。需确认是否有意为之 |
| electron 内置 Node 版本 | 28 内置 Node 18 → 44 内置版本更高；`electron` 包要求 `engines.node >= 22.12.0`，本机 v24 已满足 |

## 5. 参考

- 对齐对象：`DeepSeek-Reasonix/desktop/electron`（electron `44.2.0`）、
  `DeepSeek-Reasonix-studio-v2.13.0/desktop/electron`（`44.1.0`）
- 相关既有文档：[`../reference/electron-desktop-plan.md`](../reference/electron-desktop-plan.md)
  （Electron 壳对齐 E2 + 打包线 P1–P5）、
  [`desktop-ui-progress.md`](./desktop-ui-progress.md)（Desktop/Electron 跨会话 checkpoint）

---

## 6. electron-builder 24 → 26 的两处破坏性变更（2026-09-17 发现并修复）

> 两份都是**静默或半静默**的：一处让打包直接中止（还算好），另一处**打包成功但产物跑不起来**。

### 6.1 `win.signingHashAlgorithms` 被移走 —— 打包**直接中止**

`electron-builder.yml` 原本写：

```yaml
win:
  signingHashAlgorithms: [sha256]
```

v26 的 schema 只允许该字段出现在 `win.signtoolOptions` 下，留在 `win` 下 ⇒

```
⨯ Invalid configuration object. electron-builder 26.15.3 …
 - configuration.win should be one of these: null
```

**修复**：移入 `win.signtoolOptions`。
⚠️ **不能只删掉那一行** —— v26 该字段的**默认值是 `[sha1, sha256]`**，删掉等于把 sha1 加回来，
与原注释「只对最外层容器用 sha256」的意图相反。

### 6.2 `extraResources` 里根级 `node_modules` 被**硬编码排除** —— 打包成功但**启动即残**

**症状**（打包产物启动时）：

```
[scheduler] Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'express'
            imported from …/resources/scheduler/Server/index.js
[scheduler] refusing to start: scheduler handshake timeout (5s)
```

**根因**（`app-builder-lib/out/util/filter.js:42-45`，`createFilter`）：

```js
// filter the root node_modules, but not a subnode_modules
if (relative === "node_modules") {
    return false;
}
```

这是**无条件**的早返回，发生在任何用户 `filter` 之前 —— 所以在 `electron-builder.yml` 里
怎么写 filter 都救不回来。`resources/scheduler-dist` 的 `node_modules` 因此永远进不了包。

> 注意这**不是** `sync:scheduler` 的问题：`npm ci` 报告 `added 115 packages`，
> 源目录 `resources/scheduler-dist/node_modules` 有 106 项（含 `express`）。是复制阶段丢的。
> 也解释了为什么 `docs/plans/desktop-ui-progress.md` 里「随包 cli 自启 health 200」在
> electron-builder 24 时代成立、升级后**静默失效**。

**修复**（纯配置，`electron-builder.yml`）：把依赖作为**独立一条** `extraResources`，
`from` 直接指向 `node_modules` 目录本身 —— 这样相对根变成 `express/...`，硬编码规则不再命中，
落点仍是 Node 能向上查找到的 `resources/scheduler/node_modules`：

```yaml
extraResources:
  - from: resources/scheduler-dist
    to: scheduler
    filter: ['**/*', '!node_modules/**/*']
  - from: resources/scheduler-dist/node_modules
    to: scheduler/node_modules
    filter: ['**/*']
```

### 6.3 复现与验收

```bash
cd packages/app/Desktop
npm run build:main && npm run build:renderer      # 编译
npm run package                                    # 打包（含 sync:scheduler / sync:node）
node scripts/verify-artifact.mjs release/trha_0.1.0_amd64.deb   # → CONTRACT OK
ls release/linux-unpacked/resources/scheduler/node_modules | wc -l   # → 106（修前 0/目录不存在）
timeout 22 ./release/linux-unpacked/trha --no-sandbox &          # 启动
sleep 10 && curl -s http://127.0.0.1:3456/health                 # → {"status":"ok",...}
```

回执：`r-mu52cxfw-jnesjs`（产物契约）· `r-mu52how8-ei0sg7`（实机启动 + health）·
`r-mu52huhe-m9ivzy`（负向控制：`--no-sandbox` 缺失时红在 chrome-sandbox）。

### 6.4 本轮未做 / 未验证

- **win / mac 打包**：仍需各自平台构建机（`electron-builder.yml` 的 win/mac 段只做了 schema 层修复，未跑过）。
- **GUI 渲染**：见 §3.2 —— 只证明了主进程 + scheduler + HTTP，**没有**截图或渲染断言。
- **`chrome-sandbox` SUID**：未修（需 sudo）；当前靠 `--no-sandbox` 绕过。
- **`.npmrc` 的 electron 镜像**：仍未配置（§3.3），换机器/CI 会重现「装好了却起不来」。
