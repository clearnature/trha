{-# LANGUAGE OverloadedStrings #-}

-- | Interface language support (i18n) for the trha shell.
--
-- Pure module -- no IO -- so translation lookups are unit-testable.
--
-- Design: every user-facing string stays in English as its canonical
-- key; rendering looks the key up through 't'.  When the active language
-- is 'Zh' and the key is in 'zhDict' the Chinese translation is returned,
-- otherwise the key itself (English) is the fallback.  This keeps
-- 'En' behaviour byte-identical to the pre-i18n shell and makes missing
-- translations degrade gracefully.
module UI.I18n
  ( Lang(..)
  , parseLang
  , langName
  , tr
  , zhDict
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as M

-- | Active interface language.
data Lang
  = Zh -- ^ Chinese (default interface)
  | En -- ^ English
  deriving (Show, Eq, Ord, Bounded, Enum)

-- | Parse a language identifier (from CLI flag or settings file).
-- Unknown values fall back to 'En' so typos never crash the shell.
parseLang :: Text -> Lang
parseLang raw = case T.toLower (T.strip raw) of
  "zh"     -> Zh
  "zh-cn"  -> Zh
  "zh-hans" -> Zh
  "中文"   -> Zh
  "cn"     -> Zh
  "en"     -> En
  "en-us"  -> En
  _        -> En

-- | Short display name for a language.
langName :: Lang -> Text
langName Zh = "zh"
langName En = "en"

-- | Translate an English key into the active language.
tr :: Lang -> Text -> Text
tr En key = key
tr Zh key = M.findWithDefault key key zhDict

-- | English -> Simplified Chinese dictionary.  Keys are the canonical
-- English strings used by the shell (command descriptions, status text,
-- hints, feedback messages).
zhDict :: M.Map Text Text
zhDict = M.fromList
  [ -- Registry command descriptions (UI.Commands.Registry)
    ("Commands:", "命令：")
    -- footer usage segment (M1-4)
  , ("in", "输入")
  , ("out", "输出")
  , ("total", "累计")
  , (" · ctx ", " · 占用 ")
    -- permission ask card (M3)
  , ("Always allow ", "总是允许 ")
  , (" for future runs?", "（今后的运行）？")
  , ("Allow once", "允许一次")
  , ("Allow always", "总是允许")
  , ("Reject", "拒绝")
  , ("Yes, allow always", "是，永久允许")
  , ("No, back", "否，返回")
  , ("Approving...", "批准中…")
  , ("Denying...", "拒绝中…")
  , ("Interrupting...", "中断中…")
  , ("Leader: b sidebar · p provider · m models · s sessions · , settings · ? help · i interrupt · esc cancel"
    , "Leader：b 侧栏 · p 供应商 · m 模型 · s 会话 · , 设置 · ? 帮助 · i 中断 · esc 取消")
  , ("Unknown leader key", "未知的 leader 键")
  , ("Awaiting approval...", "等待批准…")
  , ("No session to approve", "没有会话可批准")
  , ("No session to answer", "没有会话可回答")
  , ("Show this help", "显示本帮助")
  , ("Show or set the current model", "显示或设置当前模型")
  , ("List available models", "列出可用模型")
  , ("Choose the model provider", "选择模型供应商")
  , ("Create a new session", "新建会话")
  , ("List all sessions", "列出全部会话")
  , ("Show current session/model status", "显示当前会话与模型状态")
  , ("Clear message history", "清空消息记录")
  , ("Delete a session (usage: /delete <id>)", "删除会话（用法：/delete <id>）")
  , ("Submit a plan for approval (usage: /plan <what to do>)", "提交计划待审批（用法：/plan <要做的事>）")
  , ("List registered orchestration plugins", "列出已注册的编排插件")
  , ("List or resume local sessions (usage: /resume [n])", "列出或恢复本地会话（用法：/resume [n]）")
  , ("Approve the pending plan", "批准待审批的计划")
  , ("Deny the pending plan", "拒绝待审批的计划")
  , ("Skip the pending plan step", "跳过待审批的计划步骤")
  , ("Reject the pending plan step (halts the plan)", "拒绝待审批的计划步骤（计划随之停住）")
  , ("Abandon the running plan", "放弃正在执行的计划")
  , ("Exit the application", "退出程序")
  , ("Exit the application (alias)", "退出程序（别名）")

  -- REPL banner & hints (Main)
  , ("Type '/help' for commands, '/quit' to exit", "输入 '/help' 查看命令，'/quit' 退出")
  , ("Goodbye!", "再见！")
  , ("Press Ctrl+Q to quit", "按 Ctrl+Q 退出")

  -- REPL model/session line (Main)
  , ("session: ", "会话：")

  -- Command feedback (UI.Commands)
  , ("No active sessions", "当前没有会话")
  , ("Sessions:", "会话列表：")
  , ("Error: ", "错误：")
  , ("Session created: ", "已创建会话：")
  , ("Usage: /delete <session-id>", "用法：/delete <会话ID>")
  , ("Session deleted: ", "已删除会话：")
  , ("No models available", "没有可用模型")
  , ("Models:", "可用模型：")
  , ("Model selected: ", "已选择模型：")
  , ("Current model: ", "当前模型：")
  , ("Status:", "状态：")
  , ("No plugins registered.", "未注册任何插件。")
  , ("Plugins:", "插件列表：")
  , ("Unknown command: ", "未知命令：")
  , ("Usage: /plan <what to do>", "用法：/plan <要做的事>")
  , ("No active session. Use /new to create one.", "当前没有活动会话，请用 /new 新建一个。")
  , ("Plan: ", "计划：")
  , ("Plan was not approved.", "计划未获批准。")
  , ("Plan denied.", "计划已拒绝。")
  , ("Plan was approved (unexpected).", "计划已获批准（非预期）。")
  , ("No local sessions found. Run a conversation first (transcripts are stored under ~/.trha/sessions).", "没有找到本地会话。请先进行对话（记录保存在 ~/.trha/sessions 下）。")
  , ("Local sessions:", "本地会话：")
  , ("No local session matches: ", "没有匹配的本地会话：")
  , ("Resumed ", "已恢复 ")
  , ("Usage: /model <name>", "用法：/model <模型名>")

  -- Brick UI status / system messages (UI.Brick)
  , ("Ready", "就绪")
  , ("Session: ", "会话：")
  , ("Model: ", "模型：")
  , ("Commands", "命令")
  , ("   ↑/↓ move · Enter run · Esc close", "   ↑/↓ 选择 · Enter 执行 · Esc 关闭")
  , ("No local session matches: ", "没有匹配的本地会话：")
  , ("Session ", "会话 ")
  , (" has an empty transcript.", " 的记录为空。")
  , ("Note: continuing needs the session on the orchestration side.", "提示：继续对话需要在编排端存在该会话。")
  , ("Resumed ", "已恢复 ")
  , (" turn(s)", " 轮")
  , ("Starting TUI mode...", "正在启动 TUI 界面...")
  , ("Starting CLI mode...", "正在启动 CLI 命令行...")
  -- Additional command feedback (UI.Commands / UI.Brick)
  , ("none", "无")
  , ("  Current session: ", "  当前会话：")
  , ("  Current model: ", "  当前模型：")
  , ("  Session: ", "  会话：")
  , ("  Model: ", "  模型：")
  , (" (empty transcript)", "（记录为空）")
  , ("⏸ Plan submitted — awaiting your decision (/approve or /deny).", "⏸ 计划已提交——等待你的决定（/approve 或 /deny）。")
  , (" — try /help", " —— 试试 /help")
  , (" turn(s)", " 轮")
  , ("Usage: /model <name>", "用法：/model <模型名>")
  , ("No local sessions found.", "未找到本地会话。")
  , ("No local sessions found. Run a conversation first.", "未找到本地会话，请先进行对话。")
  , ("Resume with /resume <number-or-id>.", "用 /resume <编号或ID> 恢复。")
  , ("Local sessions:", "本地会话：")
  , ("Usage: /plan <what to do>", "用法：/plan <要做的事>")
  , ("  —  ", "  —  ")
  , ("Deleted session: ", "已删除会话：")
  , ("No models available.", "没有可用模型。")
  , ("No sessions.", "没有会话。")
  , ("SSE: ", "SSE：")
  , ("Session failed: ", "会话创建失败：")
  , ("Settings:", "设置：")
  , ("View or edit settings (usage: /settings [key value])", "查看或修改设置（用法：/settings [键 值]）")
  , ("Usage: /settings <key> <value>", "用法：/settings <键 值>")
  , ("Setting updated: ", "已更新设置：")
  , ("Unknown setting key: ", "未知设置项：")
  , ("Value must be a whole number: ", "值必须为整数：")
  , ("Value must be true or false: ", "值必须为 true 或 false：")
  , ("(effective: layered defaults < ~/.trha/settings.yaml < project)", "（生效值：默认 < ~/.trha/settings.yaml < 项目配置）")
  , ("Available keys:", "可用键：")
  , ("text", "文本")
  , ("int", "整数")
  , ("bool", "布尔")
  , ("Server host for the orchestration scheduler", "编排调度器的主机地址")
  , ("Port of the orchestration scheduler", "编排调度器的端口")
  , ("Default model name for new sessions", "新会话默认模型名")
  , ("Bearer token used against the scheduler", "访问调度器使用的 Bearer 令牌")
  , ("Maximum tokens per completion", "每次完成的 Token 上限")
  , ("HTTP request timeout in milliseconds", "HTTP 请求超时（毫秒）")
  , ("Retry count for failed requests", "失败请求的重试次数")
  , ("Verbose logging", "详细日志")
  , ("TUI theme: tokyo-night | light", "TUI 主题：tokyo-night | light")
  , ("Interface language: zh | en", "界面语言：zh | en")
  , ("(default: ", "（默认：")
  , ("Settings", "设置")
  , (" settings ", " 设置 ")
  , ("↑/↓ move · Enter edit · Esc close", "↑/↓ 移动 · Enter 编辑 · Esc 关闭")
  , ("editing ", "正在编辑 ")
  , ("Enter save · Esc cancel", "Enter 保存 · Esc 取消")
  , ("Saved: ", "已保存：")
  , ("Error: ", "错误：")
  , ("Search: ", "搜索：")
  , ("no match", "无匹配")
  , ("toggle boolean (Enter)", "布尔值切换（Enter）")
  , ("Did you mean: ", "你是不是想设置：")
  , ("Status", "状态")
  , ("Stats", "统计")
  , ("←/→ to switch tabs", "←/→ 切换页")
  , ("↑ to return to tab bar", "↑ 返回页栏")
  , ("Session: none", "会话：无")
  , ("No token usage recorded yet", "尚无 token 用量记录")
  , ("Last reply tokens: ", "上次回复 tokens：")
  , ("No active session", "无活动会话")
  , ("Name", "名称")
  , ("Runtime", "运行环境")
  , ("OS", "操作系统")
  , ("Auth", "认证")
  , ("Base URL", "Base URL")
  , ("Model", "模型")
  , ("Session ID", "会话 ID")
  , ("Sandbox", "沙箱")
  , ("Memory", "内存使用")
  , ("Session", "会话")
  , ("Summary", "概括")
  , ("Performance", "性能")
  , ("Messages", "消息")
  , ("User", "用户")
  , ("Assistant", "助手")
  , ("Tools", "工具调用")
  , ("System", "系统消息")
  , ("Message chars", "消息字符数")
  , ("Last reply tokens", "上次回复 tokens")
  , ("Performance metrics not yet recorded", "性能指标尚未记录")
  , ("Message bytes", "消息字节数")
  , ("(default)", "（默认）")
  , ("Host", "主机")
  , ("Port", "端口")
  , ("Token", "令牌")
  , ("Model", "模型")
  , ("Max Tokens", "最大 Tokens")
  , ("Timeout", "超时")
  , ("Retries", "重试")
  , ("Verbose logging", "详细日志")
  , ("Theme", "主题")
  , ("Proxy", "代理")
  , ("Proxy for remote targets: unset = env | none | http://host:port", "远程目标代理：留空 = 跟随环境 | none | http://host:port（本机回环始终直连）")
  , ("Interface language", "界面语言")
  , ("↑ tabs · ↓ list · type to filter", "↑ 页栏 · ↓ 列表 · 键入过滤")
  , ("Model: ", "模型：")
  , ("Git branch: ", "Git 分支：")
  , ("Workspace: ", "工作区：")
  , ("Context: ", "上下文：")
  , (" chars", " 字符")
  , ("Tokens: ", "本次 tokens：")
  , ("Session: ", "会话：")
  , ("Status-line metrics (comma separated keys)", "状态栏指标（逗号分隔键）")
  , ("Markdown rendering", "Markdown 渲染")
  , ("Timestamps", "时间戳")
  , ("Footer hints", "底部快捷键提示")
  , ("Reply bell", "回复响铃")
  , ("Render assistant replies as markdown", "将助手回复渲染为 Markdown")
  , ("Show message timestamps", "显示消息时间戳")
  , ("Show the footer key hints", "显示底部快捷键提示")
  , ("Ring the bell when a reply completes", "回复完成时终端响铃")
  ]
