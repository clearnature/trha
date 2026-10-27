# dsh Web UI 层级穷尽清单（2026-10-27）

> 目的：把 dsh Web 的层级结构一次性列全，作为 trha Web 对齐的唯一依据。
> 所有条目均来自 `deepseek-harness` 源码路径，不是推测。

## 1. 入口链

```
apps/web/src/main.ts
  └─ AppWebEntry('#root')            @deepseek-ai/dsh-client-web
       └─ ui-renderer/src/client/app.tsx        （应用根装配）
            ├─ registry.ts / bindings.tsx        （slot 注册与 React 绑定）
            ├─ scoped-slots.tsx                  （session/root scope）
            └─ ui-layout/src/client/AppFrame.tsx （三栏 frame，root slot occupant）
```

`ui-renderer`：9 文件 / 2465 行；`ui-slots`：3 文件 / 1976 行；`ui-primitives`：132 文件 / 16788 行。

## 2. 包清单（按层）

### 2.1 外壳 / 框架
| 包 | 文件/行数 | 职责 |
|---|---|---|
| `ui-layout` | 11 / 1288 | 三栏 AppFrame、拖拽、`ctx.layout` 视图状态服务 |
| `ui-renderer` | 9 / 2465 | React slot 绑定、应用根装配 |
| `ui-slots` | 3 / 1976 | 类型化 slot 注册表、Store seat |
| `ui-primitives` | 132 / 16788 | 原子控件、图标、markdown、JSON 检视 |
| `ui-dockkit` | — | 可停靠布局 split-tree |
| `ui-theme` | 29 / 2513 | `--dsw-*` token、boot、Appearance 设置 |

### 2.2 侧栏
| 包 | 职责 |
|---|---|
| `ui-sidebar` | 侧栏外壳：会话多级树、搜索、分组、状态点 |
| `ui-sidebar-right` | 右侧栏停靠面（panel/header expand control） |
| `ui-sidebar-files` | 工作区文件树 |
| `ui-sidebar-terminal` | 终端 tab |
| `ui-sidebar-browser` | 沙箱浏览器 tab |
| `ui-sidebar-documentpreview` | Office/Markdown/代码/图片/PDF 预览 |
| `ui-workspace` | Workspace picker（sidebar + empty-state slot） |
| `ui-plugin-manager` / `ui-plugin-market` | 插件管理/市场面板 |

### 2.3 会话 / 消息 / 输入
| 包 | 文件/行数 | 职责 |
|---|---|---|
| `ui-conversation` | 90 / 15825 | Conversation 外壳、composer、queue、视图导航 |
| `ui-chat` | 120 / 15952 | Chat 节点定义、渲染器、详情面 |
| `ui-tool` | 49 / 5679 | 工具调用树渲染、按工具的 presentation slot |
| `ui-approval` | — | 审批 composer takeover |
| `ui-user-questions` | — | `ask_user_question` composer takeover、plan review |
| `ui-attachment` | — | 附件呈现插件 |
| `ui-input-trigger` | 14 / 2034 | `/` 与 `@` 触发、候选菜单 |
| `ui-commands` | 13 / 1863 | 命令目录、`/` 源、三种命令 UI |
| `ui-plan` | 15 / 779 | Plan 模式、计划卡、侧栏预览 |
| `ui-goal` | 13 / 943 | GoalBar（composer 上方） |
| `ui-jobs` / `ui-schedule` | — | 后台任务、定时任务 |
| `ui-deliverables` | — | 变更文件卡、交付卡 |
| `ui-trajectory` | — | 事件账本 + 时间线 |
| `ui-workflow-run` | — | 工作流运行节点 |
| `ui-message-feedback` / `ui-model-selection` / `ui-permission-presets` / `ui-skill` / `ui-subagent` / `ui-agent-preset` / `ui-secret-mask` / `ui-open-in-app` / `ui-reference` / `ui-directory-picker-*` | — | 各自功能面 |

### 2.4 设置
`ui-settings`、`ui-settings-account`、`ui-settings-agent-loop`、`ui-settings-general`、`ui-settings-models`、`ui-settings-plugin-inventory`、`ui-settings-plugins`、`ui-settings-session-log`、`ui-settings-shell`、`ui-settings-subagent`、`ui-settings-web-search`、`ui-shortcuts`、`ui-brand-official`。

## 3. 插槽树（出现频次 = 引用次数）

```
root
├─ sidebar                    （22）
│  ├─ sidebar.brand.mark / name / toggle.badge
│  ├─ sidebar.panellist       （7）
│  ├─ sidebar.workspaces      （4）
│  ├─ sidebar.settings        （4）
│  └─ sidebar.footer.action   （4）
├─ main                       （13）
│  ├─ main.conversation       （6）
│  └─ conversation.*          （21）
│     ├─ conversation.session / header / content
│     ├─ conversation.hero.*  （brand.mark / workspace / options）
│     ├─ conversation.composer（4）
│     ├─ conversation.input.* （left / right / plan / permission / model / activity / overlay / dock / attachments）
│     ├─ conversation.view    （11）
│     ├─ conversation.chat.flow（9）
│     ├─ conversation.chat.node（38）
│     │  ├─ conversation.chat.commandview（5）
│     │  ├─ conversation.chat.reasoning.body/content
│     │  ├─ conversation.chat.message.images / user.images / user.content
│     │  └─ conversation.user.text(.node)
│     ├─ conversation.approval.detail
│     └─ conversation.images.content
├─ rightbar                   （5）
├─ shell.bottom               （4）  ← composer 停靠
├─ shell.leading              （7）  ← 窗口 chrome（隐藏侧栏时的展开/新建）
└─ shell.overlay              （7）  ← 浮层（quota notice 等）
```

## 4. 组件树（ui-conversation + ui-chat）

```
ConversationRoot
├─ ConversationSession
│  ├─ ConversationHeader（leading / lineage / utilities / actions / corner）
│  ├─ ConversationMainPanel
│  │  └─ ConversationContent
│  │     ├─ EmptyHero（brand.mark / workspace / options）
│  │     └─ ChatView（ui-chat）
│  │        ├─ ChatFlow
│  │        │  └─ ChatNodeSeat → 按 node kind：
│  │        │     MessageItem / TurnTriggerNodeView / TurnProcessNodeView /
│  │        │     TurnTailNodeView / CompactionItem / CommandNodeView /
│  │        │     SystemPromptRow / ApprovalCommand / GenericCommandCard
│  │        ├─ AssistantMarkdown / ReasoningRow / ContextInjectionRow
│  │        ├─ StatsPills / TurnUsagePanel / MessageIconActions
│  │        ├─ TurnNavigator（右侧 turn rail）
│  │        └─ RunningStatus / RunningWhaleTail
│  ├─ QueueDock（排队消息）
│  └─ TodoPanel（计划/TODO 面）
└─ InputBar（shell.bottom）
   ├─ ComposerContentEditable（Lexical）
   │  ├─ CommandChip / ReferenceChip（decorator portals）
   │  └─ keymap / span-map / projection
   ├─ ContextMeter
   ├─ notice 行
   └─ control row（conversation.input.*）
```

## 5. 状态与交互

| 位置 | 状态 |
|---|---|
| `AppFrame` | viewport、sidebar width（0=rail）、rightbar track、dragging（pointer capture + rAF）、`data-animating`/`data-dragging` |
| `SidebarRoot` | `wide`、`collapsed`、`railIn`、`fading`、`quietBars`、`pointerInside`（滚动条 2s linger）、`lastWideWidth` |
| `ChatView` | `data-chat-following-tail`、`collapseTiming`（next-input 等）、group tree、turn rail 项 |
| `InputBar` | `useInput` 状态机、submission policy（Enter 行为）、draft chips、图片上传状态 |
| `ui-theme` | light/dark/system、字体族/字号、boot 前解析 |

## 6. 设计 token 文件（ui-theme/styles）

`design-platform.css`（静态色板 + alias）、`base.css`（radius / 字体 / 动效）、`scrollbar.css`、`focus.css`、`brand-font.css`（Montserrat）、`shiki.css`（代码高亮）、`corner-shape.css`、`onboarding.css`、`gradient-shadow-text.css`。

## 7. trha 当前映射

| dsh 层 | trha 状态 |
|---|---|
| 入口 / renderer | 无（trha 直接用 `App.tsx`） |
| slot 注册表 | 无（直接组件组合） |
| L0 token | ✅ 已移植子集（`src/styles/tokens.css`） |
| L1 AppFrame | ✅ 三栏 + 拖拽 + 折叠（`src/layout/AppFrame.tsx`） |
| L2 SidebarRoot | ✅ 结构（logoRow 60px、整行新建、footArea 左下设置、rail 36×36） |
| L3 ChatView | ⚠ 部分（turn 分组、简易 markdown、stats pills、running、跟随滚动；缺 TurnNavigator、Tool 卡、Reasoning、Approval、Compaction、SystemPrompt、图片） |
| L4 InputBar | ⚠ 部分（card 结构、contenteditable、ContextMeter；缺 Lexical chip、@引用、附件、queue、plan/permission/model 控件） |
| 右栏 | ❌ 未做（`ui-sidebar-right` 对应） |
| 设置系统 | ⚠ 单面板（无 `ui-settings-*` 分节） |
| 插件/slot 体系 | ❌ 未做（这是 dsh 的运行时基础） |

## 8. 结论

- dsh Web 是 **60+ 个插件包 + 50+ 个 slot** 的体系，`ui-layout` 只占 1288 行，大头在 `ui-conversation`(15.8k) / `ui-chat`(16k) / `ui-primitives`(16.8k)。
- 之前只做了 L1 骨架与 L2/L4 的壳，L3 是简化版；"穷尽"意味着按 §3/§4 的节点逐项补齐，而不是继续凭印象加组件。
