# dsh Web UI 分析（截至 2026-10-27，未完成）

> 目的：回答"trha Web UI 现在到底像不像 dsh"。结论是**不像**——目前只移植了布局骨架
> （`AppFrame` 三栏 + `columns.ts` + 56px 折叠），dsh 的 token 层、组件层、交互层都还没碰。

## 0. dsh Web 的五层结构（代码事实）

| 层 | 包 / 文件 | 内容 |
|---|---|---|
| L0 设计 token | `packages/client/ui-theme/src/styles/design-platform.css` | 静态色板（neutral / neutral-bluish / deepseek / green / red / amber，各 10 档）+ 语义 alias（`--dsw-alias-bg-base`、`bg-layer-1..3`、`label-*`、`border-l1..l4`、`state-business-*`、`scrollbar-*`、`brand-primary`）+ 暗色覆写 `body[data-ds-dark-theme]`；品牌字体 Montserrat（`brand-font.css`） |
| L1 框架 | `packages/client/ui-layout/src/client/AppFrame.tsx` + `columns.ts` + `AppFrame.module.css` | 三栏 grid（sidebar / center / rightbar）+ `shell.bottom` / `shell.overlay` / `shell.leading` 插槽；拖拽（pointer capture + rAF）；自动折叠（1024）；Windows 标题栏、macOS vibrancy |
| L2 侧栏外壳 | `packages/client/ui-sidebar/src/client/SidebarRoot.tsx` + `.module.css` | `padding: 6px 12px`、14px 字号；`logoRow` 高 60px（`padding: 8px 0 8px 4px`）、`brandName` 18px/600/`letter-spacing .04em`；panel 行 + `sidebar.workspaces`（会话/工作区浏览）+ `sidebar.settings` 插槽；折叠 = 滑动 + 交叉淡出（150ms，rail 图标 `translateX(49px)` 入场），落定后才切 56px rail（36×36 控件、10px 边距、12px 节奏） |
| L3 会话/消息 | `packages/client/ui-chat/src/client/chat/*`、`ui-conversation/src/client/*` | 节点化渲染（Turn / Step / NodeKey）；`AssistantMarkdown`、`TurnProcessNodeView`、`StatsPills`、`RunningStatus`、`TurnNavigator`、`MessageIconActions`；折叠时机（`collapseTiming`）、滚动策略（`use-chat-scroll`）、分组（`group-tree`）。布局规则：`.scroll` 左右 `16px + --dsh-composer-side-clearance`、`container-type: inline-size`；`.column` 以 `--dsh-chat-content-width` 居中，和输入框同轴（输入卡比 chat 宽 16px）；`data-chat-following-tail` 时关闭 `overflow-anchor` |
| L4 输入区 | `packages/client/ui-conversation/src/client/input/editor/*`、`skeleton/InputBar.tsx` | `InputBar` 结构：`root`（左右 `--dsh-composer-side-clearance`、底部 4px）→ `dock`（12px gap）→ `card`（12px 文本区/按钮行间距、圆角）→ `notice` + `ContextMeter`；文本面是 **Lexical contenteditable**（`DraftEditor` + `ComposerContentEditable`），命令/引用 chip（`CommandChip`、`ReferenceChip`、装饰 portal）、keymap、提交策略（`submission-policy`）——不是 textarea |

启动与主题：`ui-theme/src/boot-theme.ts` 在首帧前解析外观；`ui-theme/src/client/settings-store.ts` 管字体族/字号/明暗。

## 1. 当前 trha Web 对照

| 层 | trha 现状 | 差距 |
|---|---|---|
| L0 token | 自己写的一套 `--bg-base / --sidebar-bg / --surface / --border / --text / --muted / --accent`（tokyo-night 取色） | 与 dsh 的语义 token 体系完全不同；没有 layer / state / scrollbar / radius / 字号阶梯 |
| L1 框架 | `layout/columns.ts`（已移植）+ `AppFrame.tsx`（grid + 拖拽 + 折叠） | 没有 `shell.bottom` / `shell.leading` / `shell.overlay` 插槽；没有 Windows/macOS 适配 |
| L2 侧栏 | 自写 `Sidebar`：brand + `+`/`‹`、Sessions/Context/Todo/Files/Agents、Mode、footer | 没有 dsh 的 logo row / panel 行 / workspaces 浏览区 / 滑动交叉淡出；视觉与节奏完全不同 |
| L3 消息 | 简单气泡（role + 纯文本），无 markdown | 没有工具卡、stats pills、turn navigator、运行状态、折叠与滚动策略 |
| L4 输入 | `<textarea>` + Send 按钮 | 没有 contenteditable、chip、keymap、多行策略、附件/引用 |

## 2. 结论

- "布局骨架"这件事做完了，但**视觉与组件层等于从零自写**，和 dsh 不是一套东西。
- 要对齐，必须按 L0 → L2 → L3 → L4 的顺序做，token 先行；否则每个组件都会再自造一套颜色/间距。

## 3. 下一步选项

1. **只做 L0 + L2**：把 dsh 的 token 体系（裁剪成 trha 需要的子集）与侧栏外壳搬过来，先让"壳"像。
2. **L0 + L2 + L4**：加上 contenteditable 输入区（对话可用性提升最大）。
3. **完整对齐 L0–L4**：包括消息节点化、工具卡、stats、turn navigator，工作量大。
4. **维持现状**：继续补功能，不追视觉。
