# `/` 命令面板按功能分组（已实现）

状态：已实现（2026-10-27）。定案：10 组、双语组标题、`/help` 同步分组、recent 里的命令在组内重复出现。

## 1. 现状

- `slashRegistry` 共 **70 条**命令（68 条 `scPicker = True`），是唯一来源（`UI/Commands/Registry.hs`）。
- `buildPalette` 的布局：`recent`（最近 3 条命令 + 3 个技能）→ `commands`（全部按字母序）→ `skills`。
- `drawPalette`（输入框上方的内联面板）与 `DialogCommands`（Ctrl+P 全屏对话框）**已经支持 section 标题**：`sectionItem` 生成不可选中的 `#id` 行，`isSection` 用于跳过。

## 2. 分组表（8 组，覆盖 70/70）

| 组 | id | 命令 |
|---|---|---|
| 会话 | `session` | /new /sessions /status /home /resume /rename /tag /delete /fork /branch /stash /session-info /export /transcript /stats /compact /clear /cls |
| 计划与任务 | `plan` | /plan /approve /deny /skip /reject /abandon /goal /todo /tree /agents /graph /workflow /loop /queue /steer |
| 模型与供应商 | `model` | /model /models /provider /switch /fav /preset |
| 上下文与记忆 | `context` | /context /usage /memory /remember /btw /recap /retry /diff |
| 工具与服务 | `tools` | /mcp /lsp /hooks /plugins /skills /doctor /currency /attachments /clear-attachments /paste /vim /copy |
| 外观与语言 | `appearance` | /theme /language /reasoning-language /output-style /verbose |
| 权限与设置 | `settings` | /mode /ask-timeout /settings |
| 帮助与退出 | `help` | /help /quit /exit |

组顺序即上表顺序（最常用的在前）；组内按命令名字母序。

## 3. 面板效果

```
┌ Commands ───────────────────────────┐
│ recent                              │
│   /model                            │
│   /plan                             │
│ session                             │
│   /branch    /clear     /cls        │
│   /compact   /delete    /export     │
│ plan                                │
│   /abandon   /agents    /approve    │
│ model                               │
│   /fav       /model     /models     │
│ …                                   │
│ skills                              │
│   deep-research                     │
└─────────────────────────────────────┘
```

- 组标题与现有 `commands` / `skills` 同级（小写、灰色、不可选中）。
- `recent` 段保留在最上方（不重复出现在组里，还是重复？见 §5 第 4 点）。
- 输入过滤（`/mod`）时：**保留组标题、隐藏空组**，组内只留命中项；全无命中显示 `no matching command`。

## 4. 实现点

| 文件 | 改动 |
|---|---|
| `UI/Commands/Registry.hs` | 新增 `data CommandGroup = GroupSession \| GroupPlan \| …`；`groupOf :: Text -> CommandGroup`；`pickerItemsGrouped :: Lang -> [(CommandGroup, [PickerItem])]`。保留现有 `pickerItems` 以兼容。 |
| `UI/Render/Picker.hs` | `buildPalette` 增加分组版本（或新增 `buildGroupedPalette`）；section 标题用 `sectionItem`。 |
| `UI/Brick.hs` | `paletteItemsFor` 改用分组版本；`drawPalette` / `DialogCommands` 已有的 `isSection` 渲染可直接复用。 |
| `UI/Commands.hs`（可选） | `/help` 输出按组排版（复用同一张分组表）。 |
| 测试 | ① 每条 `scCommand` 恰好属于一组（无遗漏、无重复）；② 分组顺序稳定；③ 过滤 `mod` 只保留 `model` 组且组标题在；④ recent 段仍在最前。 |

## 5. 定案（2026-10-27）

1. **10 组**：`session` / `history` / `plan` / `model` / `context` / `tools` / `input` / `appearance` / `settings` / `help`。
   （在 8 组草案基础上拆出 `history`（会话数据）与 `input`（输入与附件）。）
2. **双语组标题**：中文 + 英文 id，例如 `会话 session`；英文界面只显示 id。
3. **`/help` 同步分组**：与面板共用 `groupMembers` 表。
4. **recent 重复**：recent 是快捷入口，组内仍显示完整列表。

### 实现位置

- `UI/Commands/Registry.hs`：`CommandGroup`、`commandGroups`、`groupKey`、`groupTitle`、`groupMembers`、`groupOf`、`pickerItemsGrouped`；`registryHelp` 按组输出。
- `UI/Render/Picker.hs`：`buildPalette` 接收分组 `[(id, heading, items)]`；新增 `firstSelectable` / `moveSelectionSkipping`（选择跳过组标题）。
- `UI/Dialog.hs`：`DialogCommands` 的方向键用 `moveSelectionSkipping`。
- `UI/Brick.hs`：`paletteItemsFor` 用分组构建；内联面板初始选中用 `firstSelectable`；`DialogCommands` 回车忽略组标题。
- `UI/I18n.hs`：10 个组标题 + `custom`（自定义命令段）。
