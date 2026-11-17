# W5：多模态组件链路计划（M1–M4）

> 架构定性（2026-11-17 用户裁定）：**多模态是数据解析与传输，不是本地跑模型**。理解由远程
> DeepSeek V4.1 完成；本地 IDE 需要的是组件能力——收图（已有：Ctrl+V → `~/.trha/paste/`）、
> 校验预处理（recipe image resolve）、wire 格式（CC content blocks）、token 记账
> （ImageTokenSpec 进上下文账本）。dsh 的语音本地模型是廉价 ASR 特例，不是常态。
> 前置事实：deepseek-recipe 的 CC schema **原生解析多模态 content blocks**
> （`ChatCompletionRequestContent::List[Text|ImageUrl|File]`，data URL 含在内）——
> kernel `/v1/*` 与 recipe convert/render/encode 已免费支持；FFI 的
> `image_resolve`/`image_token_spec` 已落地（trha-recipe ff1d735）。
> 断点：TUI 粘贴后发送的是 `[image: path]` **纯文本占位**，模型收到一行字。

**目标**：粘贴的图片以真正的 multimodal content block 到达远程模型，token 记账进 `/api/context`。
**执行方式**：executing-plans；步骤 `- [ ]`。

## 差距清单

| # | 现状 | 目标 |
| --- | --- | --- |
| G1 | image 能力只到 FFI（`recipeImageResolve`/`recipeImageTokenSpec`），无 HTTP 面 | `POST /api/recipe/image/resolve` + `/api/recipe/image/token-spec` |
| G2 | scheduler 消息 `content: string`；`[image: path]` 占位按纯文本发送 | 发送前占位解析成 CC content blocks（`text` + `image_url` data URL） |
| G3 | governor `estimateTokens` 只吃字符串 content | 数组 content：文本块估算 + 图片块用 resolve 返回的 token 数 |
| G4 | 粘贴无预检：坏图/超大图发送时才发现 | 粘贴/发送前 resolve 预检，失败当场提示 |

## 里程碑

### M1 kernel image 端点（G1）

- [ ] `POST /api/recipe/image/resolve`：透传 sources 载荷到 `recipeImageResolve`；401 门禁与四端点同套；错误 → 400 带库错误文本
- [ ] `POST /api/recipe/image/token-spec`：`{width,height}` → `recipeImageTokenSpec`
- [ ] RecipeEndpointsSpec：resolve（内嵌 1×1 PNG data_url → image_count=1 + total_tokens>0）/ token-spec（1024×768 → ≤1024）/ 坏图 → 400
- 验收：trha-test 全绿

### M2 scheduler 多模态消息（G2）

- [ ] `SessionMessage.content` 类型放宽：`string | ContentBlock[]`（`{type:'text',text} | {type:'image_url',image_url:{url}}`）
- [ ] runStep 发送前：扫描 user 消息里的 `[image: <path>]` 占位 → 读文件 → data URL → 替换为 blocks（非 user 消息保持 string）
- [ ] 发送前预检：blocks 里的图片先走 `/api/recipe/image/resolve`；失败 → 步骤报错并移除坏图（不静默）
- [ ] transcript 持久化/回放：blocks 原样落盘（JSON 已兼容数组）
- 验收：vitest——占位解析、坏图拒发、回放保真

### M3 governor 数组 content 记账（G3）

- [ ] `estimateMessages`/`matchesFocus`/`tailStart` 适配：数组 content 取 text 块拼接近似 + `imageTokens?: number` 字段（发送预检时写入）直接计入
- [ ] `/api/context` 的 pressure 含图片 token
- 验收：vitest——含图会话的 pressure = 文本估算 + 图片 token 数

### M4 TUI 预检与显示（G4）

- [ ] 粘贴时（`pasteImage`）fire-and-forget resolve 预检：失败 toast 提示
- [ ] `/ctx` 用量含图片 token（经 M3 的 pressure 自然生效）
- 验收：tmux 实测——粘贴 → 发送 → 回复带图理解；/ctx 数字含图片份额

## 非目标

- 不做 URL 远程图拉取的用户面（SSRF 面大，先只走本地文件→data URL）
- 不做 kernel 侧 provider wire 改造（库 schema 已吃 blocks，透传即可）
- 语音（ASR）链路不动

## 风险

- M2 是历史消息 schema 的首次结构变化：回放/审计/governor 三处消费方都要过一遍（vitest 钉）
- data URL 让单条消息体积增大（2 MiB 图 ≈ 2.7 MB base64）：transcript 与 prompt 都变大——resolve 预检里报体积，超限拒发
