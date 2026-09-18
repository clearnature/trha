# Reasonix 设置 UI 架构详细分析（trha 设置中心改造依据）

> 分析日期：2026-09-19 · 分析对象：`/home/yanli/work/DeepSeek-Reasonix/desktop/frontend`
> 方法：fable5 拓扑扫描（不只读一个文件）——入口 → 导航 → 分组 → tab → 面板组件 → 数据依赖，逐层深入末端。
> 结论先行：设置架构有 **三个层级维度**，先前只看到导航分组（8）就下结论是错的：

## 1. 三个层级维度（完整）

| 维度 | 数量 | 定义位置 | 含义 |
|---|---|---|---|
| **A. 完整设置功能区**（用户说的 11） | **11** | `SettingsPanel.tsx:388` `needsSettings` | 需要 SettingsView 数据的功能区，**每个都是真正的设置页** |
| **B. 导航分组**（nav groups） | 8 | `SettingsNavigation.tsx:35-44` `SETTINGS_TAB_GROUPS` | 左栏分组的视觉组织 |
| **C. tab 全集** | 21 | `types.ts:1642` `SettingsTab` + `SettingsNavigation.tsx:30-33` `SETTINGS_NAV_TABS` | 全部可导航项 |

**关键区分**（`SettingsPanel.tsx:387` 注释原文）：
> "These pages need SettingsView; **capability pages load their own data**."

即：**11 个功能区走 SettingsView（统一设置数据模型，44 字段）；其余 10 个 tab 是 capability 页（自带数据加载）**。

## 2. 11 个完整设置功能区（维度 A，用户所指）

| # | tab | SettingsView 字段（subset） | 面板 |
|---|---|---|---|
| 1 | general | desktopLanguage/desktopTheme/closeBehavior/telemetry/checkUpdates… | GeneralSection |
| 2 | models | defaultModel/plannerModel/visionModel/subagentModel/subagentEffort/autoPlan + modelSettingsFingerprint | ModelsSection(3 subtab: usage/access/stats) |
| 3 | providers | providers[]/officialProviders[]/providerPresets[]/providerKinds[] | provider 管理（ProviderConnections） |
| 4 | model-stats | （模型用量统计） | 统计面板 |
| 5 | bots | bot: BotSettingsView | BotsSection |
| 6 | subagents | subagentModel/subagentEffort… | SubagentsPanel |
| 7 | network | network: NetworkView | NetworkSection |
| 8 | permissions | permissions: PermissionsView + defaultToolApprovalMode | PermissionsSection |
| 9 | sandbox | sandbox: SandboxView | SandboxSection |
| 10 | appearance | desktopThemeStyle/textSize/zoom/fontFamily…（此前缀独立状态） | AppearanceOverview |
| 11 | updates | updateChannel/updaterEnabled | About/updates 面板 |

## 3. capability 页（10 个，自带数据，不需要 SettingsView）

mcp / remote / skills / plugins / memory / hooks / diagnostics / shortcuts / storage / browser

## 4. 导航分组（维度 B，8 组）—— 以用户 2026-09-19 提供的权威结构为准

```
偏好设置: 通用, 模型
模型: 模型偏好, 模型服务, 用量统计
集成与连接: 机器人, MCP 与工具, 远程 SSH
能力扩展: Agent Skills, 子智能体, 插件
记忆与上下文: 记忆
自动化与开发者: Hooks, 诊断
安全与控制: 权限, 沙箱, 网络, 浏览器控制
应用: 外观, 快捷键, 存储与路径, 关于
```
（代码对应：preferences(general,models) · model(model-preferences,providers,model-stats) · connections(bots,mcp,remote)
· capabilities(skills,subagents,plugins) · context(memory) · automation(hooks,diagnostics)
· security(permissions,sandbox,network,browser) · application(appearance,shortcuts,storage,about)）

## 5. 关键机制（末端细节）

- **入口**：`AppOverlayHost.tsx:10` 懒加载 `SettingsPanelEntry → SettingsPanel`；侧栏 `SidebarRegion.tsx:60` `onOpenSettings("general")`
- **数据**：`SettingsView`（`settingsViewTypes.ts`，44 字段）——language 字段 `desktopLanguage: ""|"en"|"zh"`（空=auto），providers 是 ProviderView[]，模型分配是 defaultModel/plannerModel/visionModel/subagentModel
- **保存**：`apply(fn)` 回廊 + busy 锁 + 错误/警告横幅 + modelApplication（模型分配生效结果带 issues）
- **导航**：Search 过滤 + 分组折叠；settingsTabIcon（21 图标）；meta 描述
- **模型设置子 tab**：`ModelsSectionProps.subtab: "usage"|"access"|"stats"` —— models 面板内部再分 3 层
- **主题**：theme/themeStyle/terminalTheme/conversationWidth/textSize/zoomPct/fontFamily（多状态 + 保存队列 `createTerminalThemeSaveQueue`）
- **国际化**：zh/en/zh-TW 三语；`useT()` 贯穿；`settings.navGroup.*`/`settings.tab.*` 全在字典
- **布局**：`ManagementPageShell` 共享（Trash/Automation/Settings 三管理页）：导航左栏 + 内容右栏；搜索清空；Escape 关闭

## 6. trha 对齐差距（现状 vs 参考）

| 项 | Reasonix | trha 现状 |
|---|---|---|
| 设置入口 | 侧栏 Settings 图标 → ManagementPageShell 全窗 | App.tsx 条件渲染弹窗面板 |
| 层级 | 分类 nav + 11 功能区 + 21 tab | 单层 listbox（theme/lang/fontSize + 平铺） |
| 模型参数 | temperature/topP/maxTokens 等 + subagent 分配 | **无**（store/port 无生成参数字段） |
| providers | ProviderView[] 完整管理 + presets | 有 ProvidersPanel（add/check/remove/defaultModel/webSearch） |
| 模型预设 | providerPresets + officialProviders + kind picker | `AddProvider`（add/fromCatalogs? 需核） |
| 语言 | zh/en/zh-TW + desktopLanguage(""|en|zh) | zh/en（已有 i18n 表）+ lang 持久化 |
| 接线 | SettingsView 44 字段全到内核 | prefs 3 字段（theme/lang/fontSize）；providers 有；模型参数无 |

## 7. 结论（改造方案骨架）

1. **层级**：8 组导航 + **11 个完整设置功能区**（对齐 Reasonix，含 capability 页预留接口）
2. **模型参数**：extends store 加 `genParams`（temperature/topP/maxTokens）+ 接线到 step 请求
3. **模型预设**：providers 已有 defaultModel + webSearch/thinking；补 preset 列表 UI
4. **双语**：现有 i18n 完善 settings.navGroup.*/settings.tab.* 词条
5. **入口**：侧栏 Settings → 全窗设置中心（GroupScene 架构参考 ManagementPageShell）