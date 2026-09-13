# 参考移植笔记：settings 命令 + cordis 插件架构对照

> 2026-09（北京时间）。来源：`/data/training/cli/qwen-code`（CLI 配置体系）、
> `/home/yanli/work/deepseek-harness`（`docs/config-catalog.md`、`docs/cordis-api/`、`docs/cordis-primer.md`）。

## 1. settings 命令（已落地）

参考实现的配置体系共性：

- **qwen-code `settingsSchema.ts`**：每个设置项是结构化元数据 —— `key / label / category /
  type / default / description / requiresRestart`，由 schema 驱动 UI、校验、文档。
- **deepseek-harness `config-catalog.md`**：全量设置目录，每个插件/能力段的设置都有
  key + 契约说明（类型、默认、作用）。

已移植到 trha（`/settings`，CLI 子包）：

| 特性 | 实现 |
|---|---|
| 查看生效配置 | `/settings`（分层：默认 < `~/.trha/settings.yaml` < 项目）|
| 修改并持久化 | `/settings <key> <value>`（原子写 `saveConfig`，0600）|
| 键类型校验 | `parseSettingValue`：text / int / bool 分型校验，错误本地化 |
| 键文档元数据 | `settingKeyDocs :: [(key, kind, desc)]`（对齐 schema 元数据），`/settings` 尾部列出可用键+类型 |
| i18n | 命令描述、输出、错误均走 `UI.I18n.tr`（zh 默认 / `--lang en`）|

预留扩展（未做）：嵌套分组键（`ui.theme` 风格）、`requiresRestart` 标注、
`/settings <key>` 单键查询、运行时热应用（host/port 需重启；lang/theme 可热应用）。

## 2. Cordis 插件架构对照（学习沉淀，Phase3 参考）

### Cordis 五核心概念（摘录自 cordis-primer）

1. **插件 = 实现 Service 的对象**（函数带可选 `inject`/`apply(ctx)`，或 `Service` 子类）。
2. **Context 是服务仓库**：服务声明稳定键 `ctx.<key>`（如 `ctx.tools`、`ctx.llm`、
   `ctx.sessions`），其他插件**按 key 找服务**而非 import 具体实现。
3. **`inject` 声明依赖**：插件声明所需服务，等其存在后再执行 → 加载顺序由
   “服务依赖”表达，而非手工引导顺序。
4. **类型化事件**：服务经 declaration merging 声明事件名，分派模式：
   `emit`（广播）、`waterfall`（链式改写）、`parallel`（扇出）、`serial`（顺序）、
   `bail`（首个终止值短路）。
5. **注册即逆转效应**：`ctx.effect()` / `ctx.on()` 安装的 prompt 段、工具 schema、
   适配器、提供方、监听器都可预测地卸载（reload/teardown 一致展开）。

### trha 现状（编排层 TS `packages/scheduler`）——已落地（2026-09 更新）

| 维度 | 落地 | 文件 / 验证 |
|---|---|---|
| 插件形态 | `PluginManager`（activate(ctx)/deactivate、`/api/plugins` GET/POST/DELETE）| `src/Plugins/Plugin.ts`；真实文件插件加载冒烟通过 |
| 服务注册表 | `ServiceRegistry`（register/get/require/names + 能力面 describe）| `src/Plugins/Registry.ts` |
| 服务发现 / inject | 插件 `inject: string[]` 注册前校验依赖；`ctx.service(name)` 解析 | cordis 单测：缺失依赖拒绝 / 注入解析 |
| 事件分派 | emit（EventEmitter）+ **waterfall / bail / parallel / serial** 全模式 + release 句柄 | `PluginManager.runWaterfall/runBail/runParallel/runSerial`；真实挂钩：`agent:tools` waterfall、`agent:step:before` bail |
| 生命周期逆转 | ctx.on/waterfall/bail 句柄登记 releases，`unregister` 全部解除 | cordis release 单测 |
| 热重载 | `startPluginWatcher`（轮询 dir + 纯 diff 计划 + 增/改/删自动 reconcile；`watchPlugins` 默认开）| `src/Plugins/watcher.ts`；端到端：加文件自动注册、删文件自动注销 |
| 工具 schema | AGENT_TOOLS 经 `agent:tools` waterfall 可被插件改写 | runStep `toolsCfg` |
| 服务能力面 | 内置服务带 capabilities（events/bridge/pluginManager）；`GET /api/services` | Registry.describe() |

### 后续候选

- `parallel`/`serial`/`waterfall`/`bail` 已实现；可按需接入更多真实挂钩（如 `agent:reply` serial 观察）
- 热重载目前为轮询（1.5s）；可换 fs.watch 事件驱动
- 服务注册表按 capability-seams 文档化为正式能力面契约
