# deepseek-recipe 全量接线计划（W1–W4）

> 事实基线（2026-11-17）：FFI 能力面已全量落地——`trha-recipe-ffi` dispatch（convert 三协议 / render v4+v41 / encode / count_text / resolve_limits / special_tokens / model_versions）+ 流会话四件套（21 个 Rust 集成测试全绿，trha-recipe 2d4449d）；Haskell 绑定层同能力面（trha 主仓 00d59ea，trha-test 320 例全绿）。
> 已接通的链路：kernel `POST /api/token-count`（单/批量）→ scheduler `Bridge.countTokens(Batch)` → contextGovernor `exactCounts`（冷启动 + pressure）。
> 本计划覆盖**尚未产生真实调用**的能力：render / encode（对话级）/ convert / resolve_limits / 模型窗口来源 / TUI /ctx / 流会话。
> 执行方式：executing-plans；步骤用 `- [ ]` 语法。

**目标：** deepseek-recipe 的每个能力都有 trha 里的真实调用方——不落成「绑定了但没人调」的装饰品。
**排序原则：** additive 端点先行（零回归风险）→ scheduler 真调用 → 用户可见的 TUI → 流会话（依赖本地推理后端，最后）。

---

## 背景判断（决定 W4 优先级的架构事实）

- 官方 DeepSeek API 在服务端已分离 `reasoning_content`，trha kernel 的 provider 适配器**不需要** recipe 流解析就能拿到思考流。
- recipe `StreamProcessor` 的真实用武之地是**raw token 输出的后端**：vLLM/SGLang 自建推理、`src/gpu-infer` 本地 GPU 推理——那里 `<think>`/`｜DSML｜` 以 token ID 形式到达，思考分割 / DSML 工具调用 / usage 归因只有库语义是对的。
- 因此 W4 门控在 provider kind（本地推理后端）上，不动官方 API 路径。

## 差距清单

| # | 现状 | 目标 | 后果 |
| --- | --- | --- | --- |
| G1 | kernel 只暴露 token-count；render/encode/convert/limits 只活在 FFI 层，无 HTTP 面 | `POST /api/recipe/{render,encode,convert,limits}` 四个类型化端点 | scheduler/TUI 无法产生真实调用 |
| G2 | governor `DEFAULT_GOVERNANCE.window` 写死 524_288 | window 取自模型 context（`/api/models` 的 `context_size`），配置可覆盖 | 非默认模型的窗口失真 |
| G3 | governor `exactCounts` 用 `count_text`（无渲染框架 token：BOS/系统标记不计入） | 升级为对话级 `encode` count（`POST /api/recipe/encode` 的 `ids=false` 形态） | pressure 系统性偏低约几十 token，阈值判断滞后 |
| G4 | TUI `/ctx` 无参只打印 `configCtxSize` 数字；无用量显示 | 无参 → 显示当前会话精确用量/窗口/治理状态（qwen 用量条形态） | 用户唯一的窗口可观测点没有真实数据 |
| G5 | scheduler 无 governor 状态出参 | `GET /api/context`（window、lastPressure、lastTrigger、lastSavedTokens、focusKept、messages 数） | /ctx 无数据源 |
| G6 | 流会话 FFI（open/feed/close/abort）无任何调用方 | kernel 为本地推理后端 provider 提供 recipe 流解析路径（kind 门控 + `TRHA_RECIPE_STREAM=0` 回退） | 流会话是死代码；本地后端思考/工具流不可用 |

## 里程碑

### W1 kernel recipe 端点（G1）— additive，先落

- [ ] `POST /api/recipe/render` `{kind, request, version?}` → `{prompt, special_ranges, model_version}`（Servant 端点 + handler 调 `recipeRender`）
- [ ] `POST /api/recipe/encode` `{kind, request, version?, ids?}` → `{count, token_ids?, model_version}`（`ids` 缺省 false——50 万 token 的响应不该默认回传）
- [ ] `POST /api/recipe/convert` `{kind, request}` → conversation JSON
- [ ] `POST /api/recipe/limits` `{kind, request, prompt_tokens, context_limit}` → `{max_tokens, top_p, model_version}`
- [ ] 端点测试（复用 FFISpec 的请求形态：模型名 `DeepSeek-V4.1-Flash` 精确拼写；`resolve_limits` 断言 thinking 默认 65536）
- 验收：四端点 HTTP 直调全通；未初始化（.so 缺失）时 503 带可读错误，不崩内核

### W2 scheduler 窗口与预算（G2+G3）

- [ ] `Bridge/Haskell.ts`：`recipeRender` / `recipeLimits` / `recipeEncodeCount` 方法（调 W1 端点）
- [ ] runStep：`exactCounts` 数据源从 `countTokensBatch` 升级为 `recipeEncodeCount` 批量（端点内循环 encode；`ids=false`）；kernel 不可达时回退 `countTokensBatch`（再回退估算——现有降级链不变）
- [ ] governor window 来源：session 初始化时从 `GET /api/models` 取当前模型 `context_size` 作 `cfg.window`；`configCtxSize`（用户 /ctx 设置）优先于模型值
- [ ] vitest：window 来源 3 例（模型值/用户覆盖/kernel 不可达回退）、exactCounts 升级 2 例
- 验收：scheduler vitest 全绿；`/ctx` 设置的窗口真实生效于 governor

### W3 TUI /ctx 真实用量（G4+G5）

- [ ] scheduler `GET /api/context`：出参 `{window, pressure, trigger, savedTokens, focusKept, messageCount, exact: bool}`（从 governor 最近一次 govern() 结果与会话状态取）
- [ ] TUI：无参 `/ctx` 改为 bridge 拉取 + 用量条渲染（`[███░░] 43% · 214k/500k · last: snip -38k`，qwen 形态）；异步兜底（Slash worker 既有模式）
- [ ] 带参 `/ctx <tokens>` 语义不变（set `configCtxSize`）
- [ ] HandlerCoverageSpec / RegistrySpec 回归钉
- 验收：tmux 实测——发几条消息后 `/ctx` 显示与计费一致的精确数字（不再只是数字回显）

### W4 recipe 流会话 → 本地推理后端（G6）— 独立细化后执行

- [ ] provider kind `gpu-infer`/`vllm`（本地后端）的 `providerStream` 内部改走 `recipe_stream_*`：backend raw chunk → InferenceChunk（`tokens` 型，附 tokenizer）→ StreamProcessor → CC chunk JSON → 现有 `StreamChunk` 事件
- [ ] `TRHA_RECIPE_STREAM=0` 全局回退开关（默认开）
- [ ] tokenizer 路径从 provider 配置取（本地后端自带 tokenizer.json）
- [ ] 端到端测试：`<think>` 分割 / `｜DSML｜` 工具调用 / usage（Rust 侧 7 例已在 FFI 层钉死语义，kernel 侧做接线测试）
- 验收：本地后端跑一轮带工具的对话，思考流与工具调用事件与官方 API 路径等价

## 非目标

- 不改 provider 适配器的官方 API 路径（服务端已分离 reasoning_content，现有解析正确）
- 不把裸 `recipe_dispatch` 曝成 HTTP 端点（内表面不直接出网；类型化收敛）
- 不做 W4 的 OpenAI/Anthropic 双协议 generator 接线（本地后端先 CC 一种）

## 风险与护栏

- W1 全 additive：新端点不碰既有路由；`other-modules`/Spec 注册按 00d59ea 模式
- W2 降级链三层（encode → count_text → 估算），任一层缺失行为与今天一致
- W3 的 `/ctx` 渲染走 Slash worker 异步（51 条命令既有基建），不阻塞键线程
- pre-push 钩子已含 `LD_LIBRARY_PATH`（recipe .so）与全量测试
