# Web UI 布局移植草案（参考 deepseek-harness）

状态：**P1 已实现**（2026-10-27）。`/studio/` 已切换为 `packages/app/Web` 的构建产物（三栏骨架 + chat + sidebar）。P2–P4 见 §4。

## 1. 现状

| 项 | 事实 |
|---|---|
| `/studio/` 现在是什么 | scheduler 托管 `packages/scheduler/studio-public/`，其 `index.html` 标题是 **"trha Desktop"** —— 内容是 Desktop renderer 的构建产物（`export:studio` 脚本复制），不是独立 Web 应用 |
| `packages/app/Web` | 独立 React + zustand 应用，但只有 4 个组件、559 行（`App` / `Sidebar` / `ChatView` / `SettingsPanel`），**没有被 scheduler 托管** |
| scheduler API | `/api/sessions`、`/api/agent/step`、`/api/events`（SSE）、`/api/models`、`/api/tools`、`/api/modes`、`/studio/versions`、`/health` |

## 2. 两个参考项目

### deepseek-harness（用户倾向）

- `apps/web`：Vite 入口，加载 `@deepseek-ai/dsh-client-web` shell；真正的布局在 `packages/client/ui-layout`。
- **`AppFrame.tsx`**：三栏 grid（`sidebar | center | rightbar`）+ `shell.bottom`（composer）+ `shell.overlay`；自己持有网格轨道、拖拽把手（pointer capture + rAF 节流）、列宽求解、侧栏槽参数。
- **`columns.ts`**（纯函数，可整体搬）：
  - `CENTER_MIN = 400`、`SIDEBAR_MIN = 264`、`SIDEBAR_MAX = 420`、`SIDEBAR_DEFAULT = 280`、`SIDEBAR_COLLAPSED = 56`、`SIDEBAR_AUTO_COLLAPSE = 1024`、`RIGHTBAR_MIN = 300`、`RIGHTBAR_MAX_RATIO = 0.7`、`RIGHTBAR_DEFAULT_RATIO = 0.45`
  - `computeColumns(viewport, sidebar, rightbar, collapsedWidth)`：右栏先收缩再让出轨道，只有没有右栏时中栏才低于最小值。
- **`AppFrame.module.css`**：grid 轨道、`data-animating`/`data-dragging` 过渡策略、窄屏折叠、Windows 标题栏与 macOS vibrancy 适配。
- 面板插件：`ui-sidebar`（`SidebarRoot` + 头部控件）、`ui-chat`（消息/工具卡/markdown）、`ui-conversation`（输入、队列、骨架屏）、`ui-sidebar-files/browser/terminal/documentpreview`、`ui-goal/schedule/trajectory`。
- 组件通过 slots/runtime/store 注入（类型来自 `dsh-client-ui-slots`），**不直接依赖具体协议**，但也不能脱离该框架单独使用。

### DeepSeek-Reasonix

- `internal/frontend`、`desktop/frontend(-next)`、`examples/frontend-page-kit`。
- Go 服务 + 前端一体，页面套件与 Go 后端绑定较深，**布局层面可参考，代码不适合直接搬**。

## 3. 可移植 / 必须重写

| 可移植（低耦合） | 必须重写 |
|---|---|
| `columns.ts` 的常量与 `computeColumns` 纯函数 | slots/runtime/store 注入机制（我们直接用 zustand） |
| 三栏 grid 骨架与 `AppFrame.module.css` 的布局规则 | 各 `ui-*` 插件组件（按 trha API 重写） |
| 拖拽（pointer capture + rAF 节流）、窄屏自动折叠、56px 折叠 rail | 国际化、快捷键系统、插件市场 |
| 侧栏/中栏/右栏的比例与最小宽度约束 | Desktop 专属逻辑（窗口控制、vibrancy） |

主题方面：布局可以沿用 harness 的结构，但颜色应使用 trha 现有的 tokyo-night / light 调色板，不引入 `--dsw-*` 全套变量。

## 4. 分阶段计划

| 阶段 | 内容 | 依赖 |
|---|---|---|
| **P1** | 用 `packages/app/Web` 实现三栏 `AppFrame`（左 sidebar / 中 chat / 右空），底部 composer；数据接 `/api/sessions` + `/api/events` SSE | `columns.ts`、现有 zustand store |
| **P2** | 侧栏内容：会话列表、上下文用量、TODO、文件、子代理树；折叠/拖拽 | scheduler `/api/sessions`、`/api/session/:id` |
| **P3** | 右栏：文件预览 / 终端 / 计划卡（可选面板） | `/api/events`、文件 API |
| **P4** | 命令面板（`/` 分组已实现）、设置页、主题切换、Markdown/工具卡 | 现有 CLI 的 Registry/主题定义 |

托管切换：scheduler 的 `/studio` 指向 `packages/app/Web/dist`（或保留 `studio-public` 作为 Desktop 的产物、另设 `/web` 路径）。

## 5. 已定案与 P1 实现

用户裁定（2026-10-27）：替换 `/studio/`、移植布局骨架、首版 P1。

实现位置：

| 文件 | 作用 |
|---|---|
| `packages/app/Web/src/layout/columns.ts` | 从 harness 移植的列宽常量与 `computeColumns`（纯函数） |
| `packages/app/Web/src/layout/AppFrame.tsx` | 三栏 grid、拖拽把手（pointer capture + rAF）、折叠 rail |
| `packages/app/Web/src/layout/AppFrame.module.css` | 轨道/拖拽/折叠的布局规则 |
| `packages/app/Web/src/components/Sidebar.tsx` | 会话列表、模式选择、折叠/主题/设置 |
| `packages/app/Web/src/components/ChatView.tsx` | 消息流 + composer |
| `packages/app/Web/src/styles/global.css` | 主题变量（tokyo-night 深色 / light） |
| `packages/scheduler/src/Server/index.ts` | `/studio` 目录优先级：`config.studioDir` → `TRHA_STUDIO_DIR` → `packages/app/Web/dist` → 旧 `studio-public` |
| `packages/app/Web/vite.config.ts` | 生产构建 `base: '/studio/'`；dev 代理 https + `secure: false` |

验证：`npx tsc --noEmit`、`npm run build`、`vitest run test/columns.test.ts`（7 例）、浏览器打开 `/studio/`（展开/折叠、渲染正常）。

### 剩余（P2–P4）

- P2：侧栏补上下文用量 / TODO / 文件 / 子代理树。
- P3：右栏（文件预览 / 终端 / 计划卡），`AppFrame` 已保留 rightbar 轨道契约。
- P4：命令面板、设置页、Markdown/工具卡渲染、SSE 流式。
