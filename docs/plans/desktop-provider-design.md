# Provider 三层移植设计（添加供应商 + 推荐预设）

> 参考实现：`DeepSeek-Reasonix-studio-v2.13.0`（Go 内核 `internal/serve/providers.go` + `internal/provider/`；前端 `ui/AddProvider.tsx` 等）。
> 目标：trha 侧等价能力（内核 Haskell + scheduler 透传 + Desktop UI）。
> 状态：**P1–P6 全部 ✅**。P1：`Core.Provider.Types` + `API.Providers` + `GET /providers`、`/providers/protocols`。P2：`API.ProviderProbe` + `POST /providers/probe`。P3：`ProviderDraft`/`ProviderKeys` + `POST /providers`/`remove`/`check` + `API.ProviderRuntime.adapterFor`。P4：scheduler 转发 `/api/providers*`。P5：前端 Port + `ProvidersPanel`/`AddProvider`/`ModelChoice`/`vendors` + 文案/样式。
> **P6 ✅（模型选择真正生效）**：内核 chat handler 支持请求里的 `"provider": "<name>"` → 从 registry 取 entry + key → `adapterFor` 构造该 provider 的 adapter（未知 provider → 404 `provider.unknown`；构造失败 → 502 `provider.adapter_unavailable`）；scheduler 的 `/api/agent/step` 接受 `provider`/`model` 并透传到内核 `/v1/chat/completions`；Desktop 的 `Port.step(..., target)` + `sessionStore.setTarget` + `ui/ModelPicker.tsx`（空=内核默认）。
> 验证：`cabal test` **37 examples/0 failures**；`scheduler` vitest **111→112 用例**（含 step 透传）；`Desktop` **28 文件/128 用例** + `tsc` 0 err；内核端到端（P6）：保存 provider → 请求带 `provider` → **由该 endpoint 回答**（桩收到 `model` 并回话），未知 provider → 404 `provider.unknown`。
> **P7 ✅（三种 wire 全部实现）**：`API.ProviderRuntime` 除 OpenAI 兼容线外，新增 **Anthropic Messages**（`{root}/v1/messages`，`x-api-key` + `anthropic-version: 2023-06-01` + 必填 `max_tokens`、顶层 `system`、tool 走 `tool_use`/`tool_result` 内容块）与 **OpenAI Responses**（`{root}/v1/responses`，`input` 项 + `function_call`/`function_call_output` + `instructions`），字段选择对齐参考实现 `internal/provider/anthropic`、`internal/provider/responses`；`adapterFor` 按三种 kind 分派，未知仍明确报错。`rootOf` 去掉 baseUrl 末尾的 `/v1`（避免 `/v1/v1/messages`）。
> P7 验证：内核端到端（同一桩 endpoint 模拟三 wire）——`provider:'anth'` → 命中 `/v1/messages`，断言请求头 `x-api-key`/`anthropic-version` 与 `max_tokens>0`，回复取自桩；`provider:'resp'` → 命中 `/v1/responses`，断言 `Bearer` 头与 `input` 数组，回复取自桩；`provider:'nope'` → 404 `provider.unknown`。
> **P8 ✅（编辑与两个开关，三层贯通）**：内核 `POST /providers/{edit,websearch,thinking}` —— `edit` 只改提到的字段（`baseUrl`/`models`/`default`/`vision` 可选；`apiKey` 空 ⇒ 保留已存 key；未知 name → 404 `provider.not_found`）；`{name,on}` 分别写 `webSearch`/`sendsThinking`（`ProviderEntry` 新增两个可空字段；`canWebSearch`/`canSetThinking` 由既有 `protocolCatalog` 的 `serverWebSearch`/`reasoningParams` 表达）。scheduler 转发这 3 条；Desktop `Port` 加 `editProvider`/`setWebSearch`/`setThinking`（SchedulerPort + MockPort 双实现）；UI 每行有**默认模型下拉** + **联网搜索/思考两个开关**（协议不支持时禁用）。
> P8 验证：`cabal test` 37/0；内核端到端 —— `edit` 后 `default` 变而 `models`/`keyEnv` 保持不变、两个开关写回 `true`；scheduler `provider-routes` **8/8**（含 3 条转发）；Desktop **29 文件/132 用例**（`port-provider` 2、`provider-panel` 8，含「协议禁用开关」断言）。
> **A1 ✅（名称规则）**：`validProviderName` 用参考实现同一条规则 `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$`；`save`/`edit` 拒绝非法名 → 400 `provider.bad_name`。
> **A2 ✅（流式按供应商分派）**：流式的归属是 **wire 而非 adapter**——`API.ProviderRuntime` 加 `StreamCall` / `streamSse`（`withResponse` + `brRead`，按 `\n\n` 分帧取 `data:`，失败以 `Left` 返回而**不抛异常**）/ `openAICompatStream`（真流式：请求体注入 `"stream": true`，`choices[0].delta.content` → `ChunkDelta`）/ `providerStream`（按 `peKind` 分派；无流式路径的 wire 回退为「阻塞调用 + 单次 emit」，adapter 解析失败发 `ChunkError`）。`API.Server` 三个 `/v1/*/stream` 端点加 `streamingTarget` → `providerEvents`（`ChunkDelta→SEVDelta`、`ChunkDone→SEVUsage`、`ChunkError→SEVError`）分派。
> A2 同时修掉一处根因：三个 SSE 端点原先硬编码 `Stream.streamDeepSeek "" model …`（**空 apiKey**），即改前**流式路径上选中的供应商/模型完全不生效**。
> A2 验证：内核端到端 `test/provider-stream.test.ts` —— 桩 OpenAI 兼容 endpoint 发两个 SSE delta，`/v1/chat/completions/stream` 带 `provider:'str'` → 命中桩 `/v1/chat/completions`、请求体 `stream:true`、`content === 'Hello from stub'`、`stream_events >= 2`、`messages` 透传。
> **A2.4 ✅（三条 wire 真流式 + tool 增量聚合）**：`anthropicStream`（命名事件 `content_block_delta`/`message_delta`，并把 `content_block_start` → `input_json_delta.partial_json` → `content_block_stop` 聚合成一次 `ChunkToolCall`）、`responsesStream`（`response.output_text.delta`，并把 `output_item.added` → `function_call_arguments.delta` → `…done` 聚合）、`openAICompatStream` 亦按 index 聚合 `delta.tool_calls`（`Map.insertWith` 拼接 name/arguments）；请求体构造提取为 `anthropicRequestBody`/`responsesRequestBody`，阻塞与流式共用一份。
> `API.Server.providerEvents` 转发 `ChunkToolCall → SEVToolCall`（**此前缺该分支 = 非穷尽模式，收到 tool 增量会运行时崩**）；3 个 SSE 端点的 JSON 现携带 tool calls：openai `message.tool_calls` + `finish_reason:"tool_calls"`、anthropic `content[].tool_use` + `stop_reason:"tool_use"`、responses `output[].function_call`。
> **A2.5 ✅（openai 线也可流式带工具）**：移除了 `/v1/chat/completions/stream` 对带 `tools` 请求的 501；`providerEvents` 增加 `[ToolSpec]` 参数，openai 端点把请求里的 tools 解析后透传给 provider（anthropic/responses 端点暂传空表，行为不变）。
> 三条线现在都有端到端验证：openai（文本 + tool 分片、tools 透传、`finish_reason:"tool_calls"`）、anthropic（文本 + `tool_use` 分片 + `input` 已解析）、responses（文本 + `function_call` 分片 + `arguments` 重组）。
> 期间端到端测试抓到并修掉一个真 bug：openai 的 tool 片段聚合用了 `Map.insertWith`，其回调是 `f new old`，原先按 `f old new` 写导致 arguments 顺序颠倒（`"a.txt"}{"path":`）。
> A2 尚未做（诚实）：未用真实 key 冒烟（所有验证基于本地桩）。
> **A3 ✅（三层贯通真流式）**：审核发现三个 `/stream` 端点**其实是假流式**（API 类型是 `Post '[JSON] Value`，handler 把事件攒进 `eventsRef` 列表、结束才一次性返回聚合 JSON；注释却写着 "returns raw WAI Application"）。改为：
> ① **内核**：API 类型改 `Raw`，handler 为 `Tagged Handler Application`（servant 0.20 的 `ServerT Raw`），用 WAI `responseStream` **每个增量立刻 `write` + `flush`**；三条 wire 各自的 SSE 帧（`emitOpenAI`/`emitAnthropic`/`emitResponses`）。
> ② **scheduler**：`HaskellBridge.queryModelStream(request, onDelta)` 用 `fetch` 逐帧消费内核 SSE、增量即时回调、按 index 聚合 tool_calls；**响应非 `text/event-stream` 即抛错**（否则会静默返回空 reply）；`runStep` 加 `onDelta`（失败回退 `queryModel`，旧内核仍可用）；`/api/agent/step` 把增量 `emit('agent:delta')` 到**已有的** SSE 通道 `/api/events/:sessionId`。scheduler 自己的 `/v1/chat/completions|messages|responses` 三个代理端点原先也是假流式（阻塞后按**空格切词**），改用 `streamReply` 逐字转发。
> ③ **前端**：`PortEvent` 加 `delta`；`normalizeEvent` 识别 `{sessionId,text}`；store 加 `streamText`（增量累积）并在 `step()` 返回后用最终文本落定 + 清空（丢帧也不会留下半句）；`MessageList` 渲染到达中的 `SayCard streaming`。
> A3 验证：`provider-stream.test.ts` 给出**时间证据** —— 桩在首个 delta 后故意等 600ms，实测 `first=1 total=602 frames=[1,601,601,601,601]`（第一帧 1ms 到达；假流式下 `first` 会等于 `total`）；`cabal test` 38/0；scheduler `tsc --noEmit` 0 错误 + **19 文件/115 用例**（含 `bridge-stream` 增量/tool 聚合/502 抛错）；Desktop `tsc --noEmit` 0 错误 + **30 文件/137 用例**。
> A3 尚未做（诚实）：未用真实 key 冒烟；旧 handler（`openaiStreamHandler` 等 3 个）已成死代码，待确认后清理。
> **A4 ✅（内核流式架构重构：流式成为 adapter 的接口能力）**：重跑内核 e2e 时暴露了两处更深的架构问题——① 三个 `/stream` 端点在**无 provider** 时仍硬编码 `Stream.streamDeepSeek ""`（空 apiKey → 抛异常 → warp 截断流，客户端只看到一个空回复）；② 流式端点把消息经 `toChatMessages` 拍平（`role:"tool"` → `ChatUser`），**工具结果丢失** → 模型每轮重发同一个 tool call，工具循环必然耗尽。根因是三套流式实现并存（`LLMAdapter` 阻塞接口 / `LLM.Stream` 硬编码 / `ProviderRuntime` wire 流式）。重构：
> ① `LLMAdapter` 增加 `llmChatToolsStream :: StreamCall` —— **流式是接口的一部分，不是特例**；`mkAdapter`（`Just stream` / `Nothing`）让没有流式路径的后端自动获得 `blockingStream` 回退（阻塞调用按增量发出），**调用方永远不必分支**。
> ② 8 处构造点全部接上：`ProviderRuntime` 的 openai/anthropic/responses 三个 adapter 复用各自的真流式（`openAICompatStream`/`anthropicStream`/`responsesStream`）；`createAdapter`/`createCPUAdapter`/`stubAdapter`/`OpenAI`/`DeepSeek` 用回退（DeepSeek 的内联工具调用提为顶层 `deepSeekTools`，阻塞与流式共用一份，杜绝漂移）。
> ③ 三个 `/stream` 端点**不再有任何 provider 分支**：`resolveStreamAdapter`（IO 版，错误作为值）解析出 adapter，端点统一调 `llmChatToolsStream`；错误以 SSE `error` 帧下发。
> ④ 消息保真：流式端点直接从 wire JSON 解析 `ChatMessage`（`parseMaybe parseJSON`），tool 结果与 assistant 的 `tool_calls` 不再被拍平。
> A4 验证：`cabal test` **38/0**；`kernel-serve`（工具循环端到端，**重构前失败 → 修复后通过**）+ `provider-stream`（三条 wire 真流式 + tool 聚合）+ `provider-probe` + `provider-dispatch` 4 文件全绿；Desktop **30 文件/137 用例**；scheduler **19 文件/115 用例**。
> A4 遗留（诚实）：`LLM.Stream`（`streamDeepSeek`/`streamAnthropic`）与 3 个旧 `*StreamHandler` 现已无引用（死代码，待确认后清理）；未用真实 key 冒烟。
**→ A5 起已全部处理，见下。**
> **A5 ✅（真流式全量：SSE 引擎归一 + 跨包改造 trha-infra）**：审核全部 6 处 `blockingStream` 回退，判定 2 处是**真妥协**（后端有能力却回退），并发现更深的根因——`LLM.Stream` 与 `ProviderRuntime` **各有一套 SSE 实现**。
> ① **SSE 引擎下沉**：`LLM.Stream` 成为唯一实现（`streamPostSse` = POST + 分帧 + 逐帧回调、不抛异常；`openAICompatStreamCall` = 文本增量 + tool 片段按 index 聚合）；`ProviderRuntime` 全面委托（删除本地 `streamSse`/`openAIDelta`/`openAIToolDeltas`/`accumulate`）。
> ② **DeepSeek adapter 真流式（含 tools）**：与阻塞路径共用**同一份** `buildDeepSeekChatRequest`，流式不丢任何能力；**OpenAI adapter 真流式**（text-only，与其 `unsupportedTools` 一致 —— 流式不偷偷承诺更多）。
> ③ **桩也真流式**：内核 `stubAdapter` 分块（30ms 间隔）+ echo adapter 分块 → e2e 因此覆盖"默认 adapter 真流式"路径。
> ④ **跨包改造 `trha-infra`**：`Infrastructure.CPU.Inference` 新增 `generateStream`（逐 token 回调），`generate` = 它的无回调版 → 两条路径不可能漂移；CPU adapter 据此接真流式。
> A5 中**测试暴露并修掉 2 个真 bug**：㈠ `generateStream` 的增量**没带分隔符** → 客户端拼接得到 `token_0token_0…`，与阻塞答案不符；㈡ CPU adapter 的 `llmChatTools = unsupportedTools`（空）而 `cpuStream` 产出文本 → **流式比阻塞多做了事**（正是我在 OpenAI adapter 上特意避免的错误）；已让阻塞路径也走同一引擎（`cpuTools`）。新增断言（`test/Spec.hs`）：CPU adapter **逐 token 回调 100 次**且拼接**逐字等于**阻塞路径的答案。
> A5 剩余回退（**诚实边界，非妥协**）：`providerStream` 的未知-wire 错误路径；CPU 引擎本身仍是**占位实现**（`take maxTokens (repeat 0)`）—— 但逐 token 的形状已固定，未来真实推理只需替换循环体。
> A5 验证：`cabal test` **39/0**（+1 新断言）；内核 e2e 4 文件 **5 passed**。
> **A6 🚧（自研 CPU 真实推理，M1 完成）**：用户选定"自研完整推理"路线。先做拓扑扫描，结论：`src/llm/Infrastructure/CPU/` 已有 ~1100 行**骨架**——标量算子（matmul/softmax/rmsNorm/rope）是**真实现**，但 BLAS/SIMD 只有"检测"（`blasSGEMM` 内部又是一份标量循环），推理本体（权重加载/前向/KV cache/采样/BPE）**完全缺失**（`generate = take maxTokens (repeat 0)`）。
> 验证前提已具备：本机有 **llama.cpp 完整源码树**（`/home/yanli/work/9060xt/llama.cpp`）——`build/bin/llama-server` 可作对照、`ggml/src/gguf.cpp` 与 `ggml/src/ggml-quants.c` 是格式与量化的参考实现、`models/*.gguf` 是真实测试文件。
> 里程碑：M1 GGUF 解析+张量抽象 ✅ · M2 反量化(F32/F16/Q8_0/Q4_0) · M3 BPE 分词 · M4 单层前向+KV cache · M5 完整前向+Sampler（greedy 与 llama-server 逐 token 一致）· M6 SIMD/BLAS/线程/量化点积。
> **M1 ✅**：`Infrastructure/CPU/GGUF.hs` —— 按 `gguf.cpp` 核实的布局解析 header/metadata(13 种值类型，**宽度按参考实现**：UINT8/16 各占 1/2 字节)/张量目录/alignment 对齐；`VArray`、幂等对齐校验、越界防护。验证：① 真实文件 `ggml-vocab-baichuan.gguf` → version=3、alignment=32、**18 条元数据全部解析**、数据区按 32 对齐（"张量数为 0"经 `od` 读字节核实为**文件事实**而非解析错位）；② **合成 GGUF**（自包含）→ 张量目录精确匹配 name/dims（最快变化在前 `[4,2]`）/type(F32=0)/offset/数据区起点/字节切片。
> A6/M1 验证：`cabal test` **41/0**；内核 e2e 4 文件通过。
> **M2 ✅（反量化，8 种类型）**：新增 `Infrastructure/CPU/Dequant.hs` —— F32/F16/Q4_0/Q4_1/Q5_0/Q5_1/Q8_0/Q8_1，**每条公式与 block 尺寸都对照 `ggml-quants.c` / `ggml-common.h` 转录**（注释里标了参考行号）。两个容易错的点已按参考实现固定：① 4-bit 类型的 nibble **低半在 `y[j]`、高半在 `y[j+16]`**（不是交错）；② Q5 的第 5 位在 `qh` 中，低半取 bit `j`、高半取 bit `j+12`（`ggml-quants.c:514-518`）。另有 `fp16ToFloat`（binary16→float，含 subnormal/inf/NaN）与 `typeBlockGeometry`（各类型的 block 元素数/字节数）。
> 过程修正：① `Quant.hs` 的旧 `quantize`/`dequantize` 是**错误占位**（F32 按 `b/128` 等，与真实格式无关）—— 保留但在新模块中提供真实实现；② `Infrastructure.CPU.Quant` 此前**从未注册到任何 stanza**（隐性缺口，已补）；③ `GGUF`/`Dequant` 一度同时列在 `trha-llm` 与 `trha-api`（后者 `visibility: public` 会把 other-modules 暴露给下游）导致模块歧义 —— 现只属于 **trha-llm**。
> M2 验证：`cabal test` **45/0**（+4 用例，全部**手算对照**：fp16 精确值 0x3C00=1.0/0xC000=-2.0、Q4_0 低半/高半顺序、Q8_0 有符号字节、F32 与"拒绝非整块元素数"）。
> **M1b ✅（SOV3：pyBitNet 三值权重容器）**：勘察用户的三值项目 `/data/trit/pyBitNet`（GF(3) {0,1,2} + 自定义架构），其权重在 `scripts/artifacts`。存在**三代格式**：`TSOV`（旧，JSON header + base64 trit）、**`SOV3`**（`sov_native/bitnet2b_warmstart.sov`，源自 **BitNet-b1.58-2B-4T**，含张量目录）、以及 7 月起的 **zip 容器**（`PK\x03\x04`）。格式以**写方** `bitnet/training/sov_checkpoint.py` 为准（save :889-908 / load :847-866）：`['SOV3'(4)][version u32][meta_len u32][meta JSON][紧密排列的权重块]`，**每字节 5 trits、base-3 高位在前**（`powers=[81,27,9,3,1]`），trits 值域 {0,1,2} **直接当 float 权重、无 scale**；writer 把 `offset` 留 0，故偏移由累积得出。
> 新增 `Infrastructure/CPU/SOV3.hs`（只注册到 trha-llm，避免 public 子库暴露导致的模块歧义）。验证（真实文件）：**423 张量**、**字节核算精确闭合**（Σsize 251,421,444B == 文件 251,458,509B − 12 − meta）、`token_emb.token_embed.weight` shape `[1536,1440]`/size `442368`（=1536×1440÷5）、首字节 `0xf2`(=242=三进制 22222) 解出 trits `[2,2,2,2]` ✓。
> M1b 验证：`cabal test` **46/0**；内核 e2e 4 文件通过。
> **M7a ✅（pyBitNet 三值模型：S² 几何静态表）**：勘察结论——pyBitNet 是 GF(3) {0,1,2} 三值项目，权威模型类是 **`bitnet/sovereign/sovereign_model.py` 的 `S2Sovereign`**（README 与 convert 脚本里的 `bitnet.sovereign_model` import 路径**已过时**）。架构：`token_emb → 60 ×S2CellLayer → content_bypass → final_norm → lm_head`，约束 **depth=60 / heads=12 / ff_mult=3 全部锁定**、dim=24n、**无位置编码**（胞腔轮转替代）、**norm 无参数**（整数 LUT）。所有权重与算子都在 GF(3) 整数域（模 3）。
> 权重来源（诚实）：`scripts/convert_bitnet_to_sov.py` 显示 `bitnet2b_warmstart.sov` 是**分布匹配的随机构造**（embedding 走随机投影、FFN 用 `multinomial` 按 BitNet 三值分布采样、`content_bypass` 与 `lm_head` 共用同一随机张量、`prototype_matrix` 随机且**未保存**）→ 不产生有意义文本，但**用于验证推理内核正确性完全够用**（判据是 Haskell 与 Python 逐位一致）。
> M7a 交付：`Infrastructure/CPU/S2Geometry.hs` —— 逐字照抄 `sovereign_model_trit.py:71-143` 的静态表（12 胞腔邻接 / 4 个 C3 轨道 / Christoffel GF(3) 符号 / GF(3) 乘法表 / direction 解析）。两处关键简化：**`CHRISTOFFEL_GF3` 每行都是 `[1,2,0]`**（shift 只取决于方向，与源胞腔无关）。
> M7a 验证：`cabal test` **49/0**（+3 用例：表逐字一致、**GF(3) 代数性质**——1 是单位元 / 2⊗2=1 / ⊗ 交换、direction 按邻居索引且非邻居回退 0）。
> M7 剩余：M7b GF(3) 算子（`gf3_rmsnorm.py`/`gf3_swiglu.py`）、M7c Christoffel transport+mix（`gf3_s2_lattice.py`）、M7d 组装前向（`sovereign_model.py:539+` + `NayinDecoder`）。
> 结构注意：`Core.Provider.Types` **只属于 trha-api**（两个库共享 `src/`，同名模块若两边都列会类型冲突、都不列会 undefined）。
> 测试注意：`test/kernel-serve.test.ts` / `provider-probe.test.ts` 用的是 `packages/scheduler/dist/cli.js`，**改动 scheduler `src` 后需先 `npm run build`**（在 `packages/scheduler`）。
> A4 自检补充（devil's advocate）：`createDeepSeekProvider`/`createOpenAIProvider` 只被 `test/Spec.hs` 使用（生产走 `adapterFor` 的真流式），故它们用 `blockingStream` 回退不影响生产；自检另发现 anthropic/responses 流式端点同样在拍平消息，已补 `anthropicChatMsg`/`responsesChatMsg`（`tool_use`/`tool_result`、`function_call`/`function_call_output` 全保真）；`resolveStreamAdapter`（IO）与 `dispatchAdapter`（Handler）逻辑重复，属已知小债。**→ 已消除（A4.6）**：两者合并为唯一的 `resolveAdapterIO`（返回带分类的 `AdapterError = UnknownProvider | UnavailableProvider`）；`dispatchAdapter` 变成薄 wrapper（`adapterRefusal` 映射 404 `provider.unknown` / 502 `provider.adapter_unavailable`），流式端点用 `adapterRefusalText` 把同一失败放进 SSE error 帧 —— **错误语义零变化，两条路径不再可能各说各话**。
> 结构注意：`Core.Provider.Types` **只属于 trha-api**（两个库共享 `src/`，同名模块若两边都列会类型冲突、都不列会 undefined）。

## 1. 架构决定

| 决策 | 选择 | 理由 |
|---|---|---|
| provider 注册表归属 | **内核**（Haskell） | provider 决定请求打到哪个 endpoint、用哪把 key，属于 LLM adapter 侧；参考源亦然 |
| 前端到达路径 | `UI → scheduler(/api/providers*) → 内核(/providers*)` | 保持既有单一前端通道（凭证/SSE/事件都在 scheduler） |
| 存储 | `~/.trha/providers.json`（临时文件 + rename 原子写） | 与 `settings.yaml`/`prefs.json` 同目录同风格 |
| 机密 | 只存 key 的来源（env 名），**key 明文不落盘** | 对齐参考源 `keyEnv`/`hasKey` 语义 |

## 2. 端点契约（内核，前端经 scheduler 透传）

| 方法 | 路径 | 请求 | 响应 |
|---|---|---|---|
| GET | `/providers` | — | `ProviderEntry[]` |
| GET | `/providers/protocols` | — | `Protocol[]` |
| POST | `/providers/probe` | `{baseUrl, apiKey}` | `ProviderProbe` |
| POST | `/providers/check` | `{name}` | `ProviderCheck` |
| POST | `/providers` | `ProviderDraft` | 保存后的 `ProviderEntry[]` |
| POST | `/providers/edit` | `ProviderEdit` | 同上 |
| POST | `/providers/remove` | `{name}` | 同上 |
| POST | `/providers/websearch` | `{name, on}` | 同上 |
| POST | `/providers/thinking` | `{name, on}` | 同上 |
| GET/POST | `/provider-setup…` | — | 首次配置向导（P6 再评估） |

## 3. 数据结构（trha 侧，与参考源同义）

```
ProviderEntry { name, kind, baseUrl, models[], default, hasKey, keyEnv?, visionModels[],
                preset, inUse, contextWindow?, headers?, extraBody? }
Protocol      { kind, discovery, serverWebSearch, reasoningParams }
ProviderStore { providers: ProviderEntry[] }
```
`kind` 取值与参考源 `KIND_LABEL` 一致：`openai` / `anthropic` / `responses` / `extension`。
`preset=true` 表示内核自带的精选条目（**由内核给**，前端不写死清单）。

## 4. 阶段划分（每阶段独立可验证）

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P1** | 内核 `Core.Provider.Types`（类型 + 规范/增删查 + 协议表）+ `API.Providers`（`providers.json` 原子读写）+ 端点 `GET /providers`、`GET /providers/protocols` | `cabal build` + `cabal test`（纯逻辑用例）+ `trha serve` 上 curl 两端点 |
| P2 | `POST /providers/probe`：探测 `{baseUrl}/models`，判协议、取模型列表/默认/视觉 | curl 真实/本地 endpoint |
| P3 | save / edit / remove / check + **按 provider 分派 adapter**（复用三协议 handler） | 存→列→用，mock endpoint |
| P4 | scheduler `/api/providers*` 透传（含凭证与错误码透传） | vitest（stub 内核） |
| P5 | Desktop `port/provider.ts` + `sse_/mock_` 实现 + `Providers/AddProvider/ModelChoice/vendors` + i18n | vitest（jsdom） |
| P6 | 联动：UI 选模型 → `step` 带 `model` → 内核按 provider 分派（即「模型」功能真正可用） | E2E |

## 5. 风险与依赖
- **真实连通需 LLM key**：P2 探测与 P3 实调用必须有可用 endpoint；无 key 时用本地/桩 endpoint 测。
- trha 内核 provider 目前是**编译期硬编码**（`createDeepSeekProvider`/`createOpenAIProvider` 且无调用点）→ P3 要引入**运行时选路**。
- 老规矩：`packages/app/CLI/trha-cli.cabal` 与根 `trha.cabal` 的双定义需同步（P1 只动 trha-core/trha-api，暂不涉及）。
