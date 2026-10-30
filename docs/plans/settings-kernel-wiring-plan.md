# UI 设置预留项 → 内核服务端能力接线计划

> 更新日期：2026-09-19 · 用 fable5 拓扑扫描 + 多路径推演产出
> 目标：让剩余「UI 完整 + 预留接口」的设置项，通过**内核（Haskell）/ scheduler（TS）新增服务端协议能力**变为真实接线。
> 已升级的 6 项（不再在本计划内）：权限引擎、沙箱写入路径、用量统计、诊断交互记录、Hooks 保存、插件列表(本轮)。

## 一、接线现状（拓扑盘点后）

| 层 | 已有能力 | 可复用 |
|---|---|---|
| scheduler | sessions/models/modes/tools/providers/plugins/permissions/hooks/usage-stats/services + SSE events + tool loop(executeTool) | 插件注册系统、权限引擎、hooks 落盘模式、usage 聚合 |
| 内核 Haskell | LLMAdapter(chat/tools/embed/models)、ProviderRuntime(DeepSeek/OpenAI)、ProviderProbe、tokenize/detokenize、provider websearch/thinking 端点 | 读/写 provider 状态 |

**结论**：多数新能力应落在 **scheduler**（已有事件/工具/插件宿主），只有 MCP/机器人/SSH 这类**外部协议**需更深集成；可先做 scheduler 侧服务端协议适配，内核仅在需要 LLM/凭据时介入。

## 二、剩余预留项 → 接线方案（含多路径推演）

### P1 优先（利用现有 scheduler 基础设施，成本低）
| 预留项 | 需要的内核服务端能力 | 方案 | 复杂度 | 复用 |
|---|---|---|---|---|
| plugins（插件） | — | ✅ **已完成**（本轮接 scheduler /api/plugins list） | ✅ | 现有插件注册 |
| memory（记忆） | scheduler 记忆存储 + 检索 | A: ~/.trha/memory.json（背景记忆+归档+反馈/项目/偏好分类），GET/PUT + 检索=本地过滤；B: 内核 vector index（过重）→ **选 A** | 中 | hooks 落盘模式 |
| model-preferences 高级项（压缩阈值/思考语言） | scheduler 会话参数持久化 | A: 扩 settingsStore 已持久（已有）；B: 内核会话档位生效（改 llmChatTools）→ **A 已够，B 待内核** | 低 | 已持久化 |
| subagents 自定义 Profile | scheduler 子代理 Profile 存储 | A: ~/.trha/subagents.json（name/desc/tools/command）+ /api/subagents；B: 内核执行子代理（重）→ **A 先** | 中 | hooks 落盘 |
| network（代理） | scheduler 代理转发 | A: /api/network proxyMode+type+url 存配置，HTTP client 用代理；B: 内核网络栈（重）→ **A** | 中 | hooks 落盘 |
| browser（浏览器控制） | Electron 内置浏览器能力 | A: Electron BrowserWindow + session（Cookie/缓存清）经 IPC；B: scheduler（无窗口，不适用）→ **A 在桌面宿主层** | 中高 | Electron IPC |
| storage（路径） | — | ✅ 已有（展示+复制；随内核配置变化属预留，无服务端动作） | ✅ | — |

### P2 优先（需外部协议集成，成本高）
| 预留项 | 需要的内核服务端能力 | 方案 | 复杂度 |
|---|---|---|---|
| bots（机器人） | 消息平台协议适配（QQ/飞书/Lark/微信/钉钉） | scheduler BotConnector：**长连接**接收（不用 webhook——那需要公网入站端口）→ 转 step → 回发；allowlist/pairing/审批见 **`remote-access-bot-plan.md`** | 高 |
| mcp（MCP 与工具） | MCP 客户端（stdio/HTTP）| scheduler McpClient：stdio/HTTP 子进程连接 server → 工具并入 executeTool | 高 |
| remote（远程 SSH） | SSH 客户端会话 | scheduler SSHClient（ssh2 或内核）：连接 → 文件浏览/终端/端口转发 | 高 |

### P3：凭据真实检查
- trha 无持久化凭据文件约定（provider apiKey 运行时传入）→ 需先定义凭据存储（如 ~/.trha/credentials.json 或 env）→ 再实现 diagnostics 凭据检查端点。
- 依赖：凭据存储设计是前置（待用户拍板）。

## 三、实现顺序建议

1. **P1-a memory**（利用 hooks 落盘模式，~1 批）
2. **P1-b subagents 自定义 Profile**（同模式）
3. **P1-c network 代理配置**（同模式）
4. **P1-d browser 浏览器控制**（Electron IPC）
5. **P2-a mcp**（MCP 客户端，最大产品价值——Reasonix 全局 MCP 11）
6. **P2-b remote SSH**、**P2-c bots**（外部协议，需平台对接）
7. **P3 凭据检查**（需先定凭据存储）

## 四、验收判据（每项接线后）
- scheduler 新增端点 + 测试（如 memory: GET/PUT /api/memory + 分类过滤测试）
- 前端面板 status 从 scaffold → done（settingsTypes）
- desktop vitest + scheduler vitest 全绿 + tsc 0err

## 五、不做的事（诚实边界）
- 不臆造凭据路径做「假装检查」——凭据存储设计是 P3 前置，待用户定。
- 不把「图 UI」当「真接线」——每项必须 scheduler 端点 + 测试 + status 升级三件齐。