# trha Desktop ↔ Scheduler 宿主契约（desktop-host-contract）

> 对齐 `docs/reference/electron-desktop-plan.md` 与 Reasonix DESKTOP_HOOKS 语义差异记录。
> 版本：契约 v1（2026-09）。

## 派生与握手
- Electron main 派生编排：`node <scheduler dist>`, env `TRHA_TOKEN`/`TRHA_PORT`/`TRHA_LEASE_STDIN=1`。
- scheduler 默认监听 **环回 127.0.0.1**（`ServerConfig.host` 可覆盖）。
- 子进程 **stdout 首行**必须是一行版本化 JSON：
  `{"v":1,"name":"trha-scheduler","port":N}`
- 宿主解析首行：`v!==1` 或 `name!=='trha-scheduler'` → **拒启**（记 stderr、释放 stdin、杀子进程）。
- 首行之后 stdout 被忽略（契约：仅一行）；**一切日志走 stderr**。

## 租约
- stdin 为租约：宿主 `stdin.end()`（before-quit / 崩溃清理）→ 子进程排空后 `exit 0`。
- 三平台不依赖信号；`kill()` 仅作 3s 未退的兜底。

## 生命周期
- `app.on('before-quit')` → `releaseScheduler()`（end stdin + 兜底 kill）。
- 子进程 `exit` 事件清引用；异常退出日志走 stderr。

## 与 Reasonix DESKTOP_HOOKS 的差异（本期不实现，仅记录）
| Reasonix（hooks 子进程）| trha 桌面（编排子进程）| 差异处理 |
|---|---|---|
| stdout/stderr 各捕获 ≤256KB 截断 | stdout 仅握手一行（超出即异常）；stderr 全量转发 | 不适用 hooks 语义 |
| exit code 驱动结果（0/非 0）| exit 0 = 正常（租约释放）；非 0 由宿主记日志 | 一致原则 |
| 特殊 stdout 注入（PostLLMCall/SessionStart 替换 reasoning/注入上下文）| 无对应（编排不回传模型内容供注入）| 若未来做会话注入，需新契约字段，不在 v1 |
| 事件 key 驱动触发 | 编排事件由 HTTP/SSE 通道承载 | 桌面经 preload 动词 + fetch/SSE，不经 hooks |

## 安全基线（webPreferences）
`sandbox: true`、`contextIsolation: true`、`nodeIntegration: false`；preload 仅暴露动词
（getToken / getSchedulerPort / getAppVersion + 只读 platform）。
