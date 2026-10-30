# 远程访问与 IM Bot 接入规划

> 状态：**规划**（2026-10-30）。前置安全修复已落地，实现未开始。
> 关联：`settings-kernel-wiring-plan.md` §P2（bots / remote SSH 两个预留项）。

## 1. 要解决的问题

用户想在**手机 / 外面**继续用 trha，而不是只在工作机终端里。这本来是个"远程访问"问题，
但三家实现证明它同时是个**安全边界**问题：

| 项目 | 做法 | 代价 |
|---|---|---|
| **DSH**（deepseek-harness） | 加 `dsh web`，带 `?token=` 的 launch URL；公网部署 | `SAFETY.md` 明确写「未做安全审计、不可当作生产可用」，建议一次性 VM；**责任转给用户** |
| **reasonix** | 走 IM bot（飞书/QQ/微信）+ allowlist + pairing +审批 | `feishu.mode = "webhook"`、`webhook_port = 8080` —— **仍需公网入站端口**，只是把风险从 HTTP API 挪到了 webhook |
| **trha（本规划）** | IM bot 的**长连接**模式 + SSH 隧道兜底 | 目标：**零入站端口** |

结论：把 harness 的 HTTP 端口暴露到公网是不可接受的方向；IM bot 是对的方向，但**必须用长连接而不是 webhook**。

## 2. 方案对比

| 方案 | 入站端口 | 身份体系 | 手机可用 | 结论 |
|---|---|---|---|---|
| A. 公网暴露 `:28433` | 需要 | 无（token 即管理员） | ✅ | ✗ 否决（DSH 的坑） |
| B. SSH 隧道（`ssh -L`） | 不需要 | SSH 密钥 | ⚠️ 手机上要 SSH 客户端 | ✅ 兜底 |
| C. Bot + **webhook** | **需要**（8080） | IM 平台 | ✅ | ✗ 没解决根本问题 |
| D. Bot + **长连接** | **不需要** | IM 平台 + allowlist | ✅ | ✅ **主方案** |

飞书 / QQ / 微信的官方 bot 都支持长连接（WebSocket 主动连平台），服务端只做出站。

## 3. 移植清单

参考 reasonix 的 `[bot]` 配置结构（已实测其字段），按复杂度排序：

| # | 项 | 说明 | 依赖 |
|---|---|---|---|
| B1 | `~/.trha/bot.yaml` schema | `allowlist`（按平台分 admins/approvers/groups/users）、`pairing`、`enabled` | — |
| B2 | 消息 → step → 回发 管道 | scheduler `BotConnector`：入站消息转成 session 的 user turn，回复按平台回发 | B1 |
| B3 | **长连接 adapter**（飞书优先） | 出站 WebSocket，零入站端口 | B2 |
| B4 | allowlist 准入 | 非白名单消息丢弃并记审计；`require_mention` 只响应 @ | B1、B2 |
| B5 | **pairing**（配对审批） | 陌生人请求 → 生成待审批条目（TTL 60 min，每平台最多 3 个）→ 管理员批准后才入 allowlist | B4 |
| B6 | bot 场景的审批姿态 | `tool_approval_mode = ask`（比 TUI 更严）：高危工具需在 IM 里回「批准」 | B2 |
| B7 | 队列语义 | `queue_mode = steer`、`debounce_ms`、`queue_cap`（防刷屏/排队雪崩） | B2 |
| B8 | QQ / 微信 adapter | 同 B3 的形状 | B3 |

`scheduler` 的 `BotConnector` 与现有 `subscribeSessionEvents` 复用：bot 只是"另一个客户端"，
不需要改动内核。

## 4. 已经就位的部分（前置）

远程思路依赖的几件事先修掉了：

- **`/v1/*` 与 `/studio` 的免鉴权只在 loopback 生效**（`ac74758`）——否则公网部署时 LLM 接口裸奔。
- **会话级 workspace**（`c1b20e9`）——多客户端各在自己的项目里。
- **`/workspace` 人类通道**（`4f04e6d`）+ `cd` 按会话根收敛（`7e3a314`）——agent 扩不了自己的沙箱根。
- **`~/.trha` 在沙箱内被遮蔽**（`347a1b6`）——token 不外泄。

## 5. 还缺的前置（实现 B 组之前必须做）

- `trha --token <token>`：远程/隧道连接目前只能靠 `TRHA_TOKEN` 环境变量。
- **CORS 白名单化**：现在是 `cors()` 全开。
- 非 loopback 监听时的启动自检：没有 token/证书就拒绝启动，并提示改用 SSH 隧道。

## 6. 验收判据

| 判据 | 方式 |
|---|---|
| 零入站端口 | `ss -ltn` 在 bot 运行时**只有 loopback**（无 8080/28433 公网绑定） |
| 非白名单被拒 | 陌生人发消息 → 丢弃 + 审计日志有记录 |
| pairing 生效 | 待审批条目按 TTL 过期；批准后才进入 allowlist |
| 高危工具需审批 | bot 里触发写操作 → 等待 IM 回复「批准」才执行 |
| 断线自愈 | 长连接断开后指数退避重连，不丢队列 |

## 7. 不做什么

- **不做**公网直连 + token（方案 A）——token 一旦泄漏等于管理员。
- **不把** webhook 模式作为默认——它把问题原样搬到 8080。
- **不承诺**bot 可达性属于安全边界：与 `SAFETY.md` 的立场一致，bot 仍是"减少风险"而非"保证隔离"。
