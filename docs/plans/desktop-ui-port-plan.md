# Desktop UI 完整移植计划（对照 Reasonix Studio frontend-next）

> 2026-09（北京时间）。目标：trha Desktop（Electron + React + Vite）完整桌面 UI，
> 参照 `/home/yanli/work/DeepSeek-Reasonix-studio-v2.11.0/desktop/frontend-next`。
> 约束：遵循 Electron 外壳架构（已就绪：派生 scheduler/握手/租约/随包 node）、
> 前端↔后端解耦、内核↔外壳分离（桌面为纯外壳，scheduler+内核为后端）。

## 1. 参考源分析（frontend-next 拓扑，React+Vite 同栈）

```
src/
├─ port/       能力门面（唯一后端入口）+ 双实现：
│              sse_*（真实，经 SSE/HTTP 通道）+ mock_*（UI 无后端可测）
│              port.ts AgentPort：providerSetup/models/complete/skills/plugins/
│              hooks/memories/usage/rewind/saveText…（能力面远超 trha，只移植子集）
│              session/hub/network/theme/look/boundary/storage/workspace…
├─ state/      session.ts(会话流)/graph/prefs/prompts/trajectory/usage（客户端状态）
├─ ui/
│  ├─ Shell.tsx 主壳（窗口/布局/pane）
│  ├─ cards/   消息流卡：UserCard · SayCard(assistant) · ToolCard · ToolOutput ·
│  │            ApprovalCard(计划) · AskCard · NoticeCard · ReadsCard ·
│  │            ReceiptCard · RememberCard · RewindControl · CompactionCard
│  ├─ panels/  侧栏/面板：Agents · Cache · Context · Cost · Extensions · Files ·
│  │            Jobs · Mcp · Runtime
│  └─ 其它：Menu/AccountRow/Pane/Sky/Welcome/Task/Metrics/Sandbox/Transcript/Roles/Usage
└─ i18n/ styles/（vite、pnpm）
```
关键借鉴（不照抄代码，版权独立重写）：
1. **port 门面 + sse/mock 双实现**——前端只依赖接口；UI 测试跑 mock（无后端）。
2. **cards 消息卡模型**：每个事件类型一种卡（用户/助手流式/工具/审批/提问/通知），
   transcript/SSE 事件 → 卡列表 = 会话视图。
3. **state 单层**：会话流状态机（session.ts）+ 投影（usage/graph）。
4. Shell/Pane 组合式布局（窗口级：侧栏/主区/面板可拆）。

## 2. trha Desktop 现状（差距基线）
| 面 | 现状 |
|---|---|
| 壳 | Electron main（派生 scheduler+握手+租约+随包 node ✅）；renderer：App.tsx+Sidebar+ChatView+SettingsPanel+appStore（zustand）+apiConfig 双模式（Electron preload / `/studio` 同源）|
| 会话/聊天 | 基础：createSession/sendMessage/loadModes/loadModels/loadTools；**无流式、无工具卡/计划卡 UI、无 resume、无 transcript 视图** |
| 设置 | SettingsPanel 雏形（未连 15 键 schema）|
| 主题/i18n | light/dark 简单切换；无 i18n 面 |
| 后端通道 | HTTP fetch（同源/带 token）+ scheduler SSE `/api/events/:sessionId`（agent:message/tool:update/plan/decision）——SSE 可驱动流式 |

## 3. 路径推演
- **A 照抄组件**：直接移植 Shell/cards/panels 结构与交互 → 高依赖不可照搬（Reasonix 能力面差异大、许可/命名需重写），且无后端对应能力会悬空。
- **B（选）port 门面优先 + trha 能力子集卡**：先立 `port/`（session/modes/tools/usage…）+ sse 实现 + mock；UI 按 trha 真实事件做卡（user/assistant 流式/tool/plan/notice）；panels 只做有数据的面（Settings/Status/Cost→无遥测用占位）。可测、每步垂直可用。
- 风险：B 前期形态比 A 简单——接受（先能力正确再视觉丰满）。

## 4. 原子任务分解（每原子：实现+验收）
### U0 基建：port 门面与测试通道
- T1 `port.ts` 能力子集接口：SessionPort(Modes/Models/Tools/Session CRUD/Step/PlanDecision/Subscribe) + HubPort(会话事件) → 验收：TS 类型 + mock 全量实现
- T2 sse 实现（包 scheduler SSE 事件→回调解流）+ http 实现；mock 实现 → 验收：vitest（stub 通道回放 transcript 样例）
- T3 state：sessionStore 重构接 port（去掉 appStore 直 fetch）；流式块模型（chunk 累积）→ 验收：单元（mock 驱动流式拼卡）

### U1 壳与布局
- T4 Shell.tsx 等效：侧栏（会话列表+New）+ 主聊天区 + 底部状态行（模型/会话/指标）+ 设置入口 → 验收：vitest（jsdom render）+ 冒烟
- T5 会话管理 UI：create/list/delete/rename?+resume（服务端持久化 sid 续聊）→ 验收：mock 交互测试
### U2 消息卡流
- T6 卡组件：UserCard/SayCard(流式)/ToolCard(名称+参数+状态+耗时)/NoticeCard(错误) → 验收：样例数据渲染快照
- T7 Plan/Ask 卡（approve/deny 动词，走 decision API）→ 验收：mock decision roundtrip
- T8 transcript 视图/空态/欢迎文案 → 验收：渲染+文案清单（中英）
### U3 设置与外观
- T9 SettingsPanel 接 15 键 schema（/settings 语义：读生效/改持久化 stateDir?桌面连 scheduler 设置属 CLI 文件——面板读 scheduler /studio/versions+能力而非 CLI 文件；桌面设置=本地 prefs：theme/lang/字体等本地 + 展示后端状态）→ 验收：本地 prefs 读写 + 后端版本显示
- T10 主题两套 + i18n 骨架（zh/en 最小键集）→ 验收：切换快照
### U4 收口
- T11 E2E 冒烟脚本（随包 scheduler 起 → UI 建会话/发消息/收卡）；win/mac 交叉打包冒烟（发布线）
- T12 清理：移除未用旧 appStore 直连路径；文档（port 契约表/事件卡映射）

## 5. 分批建议（按预算分会话）
批次1 = U0（T1–T3，纯前端 port 基建+测试，不动视觉）——本轮实施起点
批次2 = U1+U2（T4–T8，会话/消息卡垂直切片）
批次3 = U3+U4（设置/主题/i18n+E2E）

## 6. 解耦/分离核对（落地即满足）
- 前端↔后端：UI 仅依赖 `port/` 接口；sse_*/mock_* 注入；无 UI 直 fetch。
- 内核/外壳：renderer 无 node、无内核代码；全部经 HTTP/SSE 走 scheduler；Electron 壳只做进程/窗口/资源。
