# Desktop Port 契约（UI ↔ 后端解耦）

> 本文档是桌面 UI 与运行时之间的**唯一**接口契约。UI 组件只允许经由
> `src/renderer/port/` 暴露的 `Port` 接口访问后端；禁止组件内直接 `fetch`。
> 相关：`docs/desktop-ui-port-plan.md`（设计）、`docs/desktop-ui-execution-plan.md`（原子与状态）。

## 1. Port 接口表（`src/renderer/port/port.ts`）

| 方法 | 语义 | scheduler 端点 / 实现 |
|---|---|---|
| `modes()` | 模式表 | `GET /api/modes` |
| `models()` | 模型列表 | `GET /api/models` |
| `tools(mode?)` | 工具列表（按模式过滤） | `GET /api/tools?mode=` |
| `listSessions()` | 会话列表 | `GET /api/sessions` |
| `getSession(id)` | 单会话（404 → 抛错） | `GET /api/session/:id` |
| `sessionMessages(id)` | 会话消息 | `GET /api/session/:id/messages` |
| `createSession(mode)` | 新建会话 | `POST /api/session/start` |
| `deleteSession(id)` | 删除会话 | `DELETE /api/session/:id` |
| `step(id, message, requireApproval?)` | 执行一步 | `POST /api/agent/step`（三态返回，见 §3） |
| `decision(id, approve)` | 批准/拒绝计划 | `POST /api/session/:id/decision` |
| `subscribe(id, onEvent)` | 订阅会话事件流 | `GET /api/events/:id`（SSE，见 §4） |
| `studioVersion()` | 内核版本/pin | `GET /studio/versions` |

### 实现与装配
| 实现 | 文件 | 用途 |
|---|---|---|
| `MockPort` | `port/mock.ts` | 测试/无后端开发（内存 fixture + `emitMock`） |
| `SchedulerPort` | `port/http.ts` | 真实运行（REST + SSE，统一 Bearer 头） |
| 纯函数 | `port/sse.ts` | `normalizeEvent` / `consumeSse`（分块、坏帧、中止容错） |
| 装配 | `port/index.ts` `createPort()` | `mock:true` 或 vitest（MODE=test）→ mock；否则读 `runtime` |
| 运行时 | `port/runtime.ts` | `setApiRuntime(cfg, token)`（由 `appStore.initAPI` 在启动时写入） |

`createPort({mock:false})` 优先于 test 默认；未配置 runtime 时回退 MockPort 并告警。

## 2. 连接与凭证（宿主契约）

| 面 | 规则 |
|---|---|
| 绑定 | 默认 `127.0.0.1`（环回） |
| 读 | 无 Origin 的环回读**放行** |
| 写 | 需 `Authorization: Bearer <token>`（否则 401） |
| 跨源 | 携带 Origin 且跨源 → 403 `code:'origin'` |
| 会话 cookie | `trha_session`（HttpOnly，SameSite=Strict） |
| 同源 `/studio` | 无 token（页面同源） |

E2E 冒烟按此断言：`GET /api/sessions` 无 token → 200；`POST /api/session/start` 无 token → 401。

## 3. `step()` 三态返回

| 形状 | 触发 | UI 行为 |
|---|---|---|
| `{reply, messages, mode}` | 正常完成 | 追加 assistant 卡（文本来自返回值） |
| `{status:'awaiting_approval', pending:{message}, mode}` | 需审批 | 挂起 → `PlanCard` 等决定 |
| 事件 `plan` | 同上的实时推送 | 同上（`subscribe` 通道） |

`decision()` → `{status:'approved'|'denied'}`；approved 时附 `reply`。

## 4. 事件 → 卡片映射（`sse.normalizeEvent`）

| 服务端事件载荷 | PortEvent | UI 卡片 | 组件 |
|---|---|---|---|
| `{role:'user'\|'assistant', content}` | `{type:'message',…}` | 用户/助手 | `UserCard` / `SayCard` |
| `{name, args, status, durationMs?, error?}` | `{type:'tool', tool}` | 工具 | `ToolCard` |
| `{status:'awaiting_approval', message}` | `{type:'plan',…}` | 计划审批 | `PlanCard`（容器 `PlanPrompt`） |
| `{approve:boolean}` | `{type:'decision',…}` | 清空挂起 | — |
| （内核暂无 ask 能力） | — | 提问占位 | `AskCard`（`available=false` 时隐藏） |
| 本地错误/系统提示 | `{kind:'notice'}` | 通知 | `NoticeCard` |

**去重设计**：assistant 文本唯一来自 `step()` 返回值；事件流的 `message` 事件不追加文本，
避免同一回复被计两次。工具/计划/决定走事件流以获得实时性。

## 5. 状态与组件布局

| 层 | 文件 | 说明 |
|---|---|---|
| 会话模型 | `state/sessionStore.ts` | `makeSessionStore(port)`；`sessions/currentId/uiMessages/busy/pendingPlan/modes/models/tools/version` |
| 注入 | `ui/SessionContext.tsx` | `SessionProvider`（可注入 store/port）、`useSession`、`useSessionStore` |
| 偏好 | `state/prefs.ts` + `ui/PrefsContext.tsx` | theme/lang/fontSize；electron preload 动词优先，localStorage 回退 |
| 文案 | `ui/i18n.ts` | zh/en 键集，`MessageKey` 由 zh 表推导；`useT()` |
| 壳 | `ui/Shell.tsx` | 三区插槽（sidebar \| main \| statusBar） |
| 卡 | `ui/cards/*` | User/Say/Tool/Notice/Plan/Ask |
| Markdown | `ui/markdown.tsx` | 无依赖，React 节点渲染（不注入 HTML） |

## 6. 本地偏好（prefs）

| 键 | 取值 | 校验 |
|---|---|---|
| `theme` | `light` \| `dark` | 非法 → `light` |
| `lang` | `zh` \| `en` | 非法 → `zh` |
| `fontSize` | 10–24 | 越界/非数 → 14，且取整 |

持久化：Electron 下经 preload `getPrefs/setPrefs` → 主进程写 `<userData>/prefs.json`（临时文件 + rename 原子替换）；
否则 `localStorage['trha.prefs']`。写入为 best-effort（失败不打断 UI）。

## 7. 验证入口

| 命令 | 覆盖 |
|---|---|
| `npx tsc --noEmit` | 类型（含 main/preload/shared） |
| `npx vitest run` | 单元 + 组件（jsdom） + E2E 协议冒烟 |
| `node scripts/e2e-desktop.mjs` | 随包链协议冒烟（握手 → API → 租约退出；输出 `RESULT: PASS`） |

**待补**：GUI 级 UI 冒烟（需可显示 Electron 宿主）尚未纳入；当前 E2E 为协议级（见执行计划 §4.2 降级规则）。
