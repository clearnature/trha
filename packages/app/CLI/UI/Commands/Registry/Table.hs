{-# LANGUAGE OverloadedStrings #-}

-- | 斜杠命令定义表：@SlashCommand@ 的字段与唯一的 @slashRegistry@ 列表。
--
-- 从 "UI.Commands.Registry" 拆出。这是**纯数据**——加一个命令只需在这里加一行：
-- 命令名、表面、描述和解析动作都在同一行（执行在 UI.Commands.* 领域模块，
-- 文案在 UI.I18n.Zh）。@scParse@ 让 Registry.Table 成为解析的唯一来源
-- （Registry.Parser 只是套壳），「表里声明了、解析器忘了分支」的漂移
-- 在结构上不可能发生（cf. Reasonix 双目录事故）。
module UI.Commands.Registry.Table
  ( Surface(..)
  , SlashCommand(..)
  , slashRegistry
  , commandArgs
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import UI.Commands.Registry.Types (Command(..))

-- | 命令适用的表面。一条命令只应列它**真正实现**了的表面；
-- 「TUI 有、REPL 还是占位」的命令在补全前只标 'STui'。
data Surface = STui | SRepl
  deriving (Show, Eq)

-- | 两个表面都支持。
bothSurfaces :: [Surface]
bothSurfaces = [STui, SRepl]

data SlashCommand = SlashCommand
  { scCommand  :: Text       -- ^ canonical name, e.g. @"/model"@
  , scHasArg   :: Bool       -- ^ requires (or accepts) a parameter
  , scPicker   :: Bool       -- ^ offer in the TUI quick picker (runnable as-is)
  , scDesc     :: Text       -- ^ one-line help text
  , scSurfaces :: [Surface]  -- ^ which surfaces have a real implementation
  , scParse    :: Text -> Command
                               -- ^ 把参数文本（首词之后的部分，词已重组）变成
                               --   'Command'。无参命令忽略参数。
  }

-- | 参数串的第一个词（@/delete a b@ 只取 @a@——与旧解析分支逐条对齐）。
firstToken :: Text -> Text
firstToken = T.unwords . take 1 . T.words

-- | 参数串的第一个词，没有参数时 'Nothing'（对应旧解析的 @[] → Nothing@）。
optToken :: Text -> Maybe Text
optToken t = case T.words t of
  []  -> Nothing
  (w : _) -> Just w

-- | The command registry -- the single list every UI derives its
-- candidates from.
slashRegistry :: [SlashCommand]
slashRegistry =
  [ SlashCommand "/help"     False True  "Show this help" bothSurfaces (\_ -> Help)
  , SlashCommand "/model"    True  True  "Show or set the current model" bothSurfaces
      (\a -> if T.null (T.strip a) then ShowModel else SelectModel (firstToken a))
  , SlashCommand "/models"   False True  "List available models" bothSurfaces (\_ -> Models)
  , SlashCommand "/provider" True  True  "Choose the model provider" bothSurfaces
      (\a -> if T.null (T.strip a) then Providers else SwitchProvider (Just (firstToken a)))
  , SlashCommand "/new"      False True  "Create a new session" bothSurfaces (\_ -> CreateSession)
  , SlashCommand "/sessions" False True  "List all sessions" bothSurfaces (\_ -> Sessions)
  , SlashCommand "/status"   False True  "Show current session/model status" bothSurfaces (\_ -> Status)
  , SlashCommand "/home"     False True  "Back to the Home screen (recent sessions)" [STui] (\_ -> Home)
  , SlashCommand "/stash"    True  True  "Park or restore a draft (usage: /stash [pop|list])" bothSurfaces StashDraft
  , SlashCommand "/fav"      True  True  "Pin/unpin a favourite model (usage: /fav [model])" bothSurfaces Fav
  , SlashCommand "/skills"   False True  "List discovered skills" bothSurfaces (\_ -> Skills)
  , SlashCommand "/theme"    True  True  "List or switch the colour theme (usage: /theme [name])" bothSurfaces SetTheme
  , SlashCommand "/mode"     True  True  "Cycle or set the permission posture (usage: /mode [read-only|ask|auto|yolo|plan])" bothSurfaces Mode
  , SlashCommand "/copy"     False True  "Copy the last assistant message" [STui] (\_ -> CopyLast)
  , SlashCommand "/mouse"    True  False "Toggle mouse capture (usage: /mouse [on|off])" [STui]
      (\a -> SetMouseCapture (case map T.toLower (T.words a) of
                                ["on"]  -> Just True
                                ["off"] -> Just False
                                _       -> Nothing))
  , SlashCommand "/verbose"  False True  "Toggle verbose tool output" [STui] (\_ -> Verbose)
  , SlashCommand "/todo"     False True  "Show team tasks" bothSurfaces (\_ -> Todo)
  , SlashCommand "/tree"     False True  "Show the agent session tree" bothSurfaces (\_ -> Tree)
  , SlashCommand "/agents"   False True  "Show agent sessions in a dialog" bothSurfaces (\_ -> Agents)
  , SlashCommand "/sandbox"  False True  "SandBox: toggle enforcement and tune policy/network" bothSurfaces (\_ -> Sandbox)
  , SlashCommand "/rename"   True  True  "Rename the active session (usage: /rename <title>)" bothSurfaces Rename
  , SlashCommand "/tag"      True  True  "Set session tags (usage: /tag <tag> [tag...])" bothSurfaces Tag
  , SlashCommand "/export"   True  True  "Export the transcript (usage: /export [json|md] [path])" bothSurfaces Export
  , SlashCommand "/settings" True  True  "View or edit settings (usage: /settings [key value])" bothSurfaces
      (\a -> case T.words (T.strip a) of
                []      -> ShowSettings
                (k : ks) -> SetSetting k (T.unwords ks))
  , SlashCommand "/language" True  True  "Switch the CLI language (usage: /language [code])" bothSurfaces (SetLanguage . optToken)
  , SlashCommand "/diff"     False True  "Show the working-tree diff" bothSurfaces (\_ -> ShowDiff)
  , SlashCommand "/context"  False True  "Show context-window usage" bothSurfaces (\_ -> ShowContext)
  , SlashCommand "/doctor"   False True  "Check scheduler, provider, fonts and settings" bothSurfaces (\_ -> Doctor)
  , SlashCommand "/memory"   False True  "Show remembered notes (~/.trha/memories)" bothSurfaces (\_ -> ShowMemory)
  , SlashCommand "/remember" True  True  "Append a note to memory (usage: /remember <text>)" bothSurfaces Remember
  , SlashCommand "/shell"    True  True  "Run a local shell command (usage: /shell <cmd>)" bothSurfaces RunShell
  , SlashCommand "/stats"    False True  "Show transcript statistics for this session" bothSurfaces (\_ -> ShowStats)
  , SlashCommand "/usage"    False True  "Show account balance and the active model" bothSurfaces (\_ -> ShowUsage)
  , SlashCommand "/compact"  True  True  "Compact the conversation history (usage: /compact [focus])" bothSurfaces Compact
  , SlashCommand "/attachments" False True "List queued clipboard attachments" bothSurfaces (\_ -> ShowAttachments)
  , SlashCommand "/clear-attachments" False True "Drop all queued clipboard attachments" bothSurfaces (\_ -> ClearAttachments)
  , SlashCommand "/mcp"      False True  "Show MCP server status" bothSurfaces (\_ -> ShowMcp)
  , SlashCommand "/lsp"      False True  "Show LSP server status" bothSurfaces (\_ -> ShowLsp)
  , SlashCommand "/preset"   False True  "List built-in provider presets" bothSurfaces (\_ -> ShowPresets)
  , SlashCommand "/hooks"    False True  "List configured hooks" bothSurfaces (\_ -> ShowHooks)
  , SlashCommand "/paste"    True  True  "Attach a clipboard image (usage: /paste [text])" bothSurfaces Paste
  , SlashCommand "/vim"      False True  "Edit the next message in $EDITOR" bothSurfaces (\_ -> EditPrompt)
  , SlashCommand "/output-style" True True "Show or set the reply style (default|concise|detailed)" bothSurfaces (OutputStyle . optToken)
  , SlashCommand "/session-info" False True "Show session details (mode, goal, todos)" bothSurfaces (\_ -> SessionInfoView)
  , SlashCommand "/transcript" False True "Replay the current session transcript" bothSurfaces (\_ -> TranscriptView)
  , SlashCommand "/retry"    False True  "Retry the last turn exactly" bothSurfaces (\_ -> Retry)
  , SlashCommand "/btw"      True  True  "Ask a side question without changing the conversation" bothSurfaces Btw
  , SlashCommand "/workspace" True True  "Show or change the session workspace (human-only; agents cannot reach it)" bothSurfaces
      (\a -> Workspace (case T.strip a of s | T.null s -> Nothing; s' -> Just s'))
  , SlashCommand "/recap"    False True  "Summarize the conversation so far" bothSurfaces (\_ -> Recap)
  , SlashCommand "/queue"    True  True  "Queue a message for after this turn (usage: /queue [message])" bothSurfaces
      (\a -> Queue (case T.strip a of s | T.null s -> Nothing; s' -> Just s'))
  , SlashCommand "/steer"    True  True  "Steer the running turn (usage: /steer <prompt>)" bothSurfaces Steer
  , SlashCommand "/fork"     True  True  "Fork this session into a child (usage: /fork [title])" bothSurfaces Fork
  , SlashCommand "/branch"   False True  "Fork just before the last user turn" bothSurfaces (\_ -> Branch)
  , SlashCommand "/goal"     False True  "Show the session goal and todo count" bothSurfaces (\_ -> GoalView)
  , SlashCommand "/switch"   True  True  "Switch the active provider (usage: /switch [name])" bothSurfaces (SwitchProvider . optToken)
  , SlashCommand "/loop"     True  True  "Run a prompt on an interval (usage: /loop <30s|5m|1h> <prompt> | /loop stop)" bothSurfaces Loop
  , SlashCommand "/graph"    False True  "Show the session tree and tool-call counts" bothSurfaces (\_ -> Graph)
  , SlashCommand "/workflow" True  True  "Run a workflow template (usage: /workflow [name] [input])" bothSurfaces Workflow
  , SlashCommand "/currency" True  True  "Show or edit manual currency rates (usage: /currency [set CODE RATE | base CODE])" bothSurfaces Currency
  , SlashCommand "/cls"      False True  "Clear the transcript view (history is kept)" bothSurfaces (\_ -> Cls)
  , SlashCommand "/ask-timeout" True True "Show or set the approval wait in seconds (usage: /ask-timeout [seconds])" bothSurfaces (AskTimeout . optToken)
  , SlashCommand "/reasoning-language" True True "Show or set the reasoning language (usage: /reasoning-language [auto|zh-Hans|en])" bothSurfaces (ReasoningLanguage . optToken)
  , SlashCommand "/clear"    False True  "Clear message history" [STui] (\_ -> Clear)
  , SlashCommand "/delete"   True  False "Delete a session (usage: /delete <id>)" bothSurfaces (DeleteSession . T.unpack . firstToken)
  , SlashCommand "/plan"     True  False "Submit a plan for approval (usage: /plan <what to do>)" bothSurfaces Plan
  , SlashCommand "/plugins"  False True  "List registered orchestration plugins" bothSurfaces (\_ -> Plugins)
  , SlashCommand "/resume"   False True  "List or resume local sessions (usage: /resume [n])" bothSurfaces
      (\a -> maybe ResumeList (ResumeSelect . T.unpack) (optToken a))
  , SlashCommand "/approve"  False True  "Approve the pending plan" bothSurfaces (\_ -> Approve)
  , SlashCommand "/deny"     False True  "Deny the pending plan (usage: /deny [reason])" bothSurfaces
      (\a -> if T.null (T.strip a) then Deny else DenyWith a)
  , SlashCommand "/skip"     False True  "Skip the pending plan step" bothSurfaces (\_ -> SkipStep)
  , SlashCommand "/reject"   False True  "Reject the pending plan step (halts the plan)" bothSurfaces (\_ -> RejectStep)
  , SlashCommand "/abandon"  False True  "Abandon the running plan" bothSurfaces (\_ -> AbandonPlan)
  , SlashCommand "/quit"     False True  "Exit the application" bothSurfaces (\_ -> Quit)
  , SlashCommand "/exit"     False True  "Exit the application (alias)" bothSurfaces (\_ -> Quit)
  , SlashCommand "/stop"     True  False "Stop the kernel and scheduler (usage: /stop confirm)" bothSurfaces
      (\a -> if T.strip a == "confirm" then StopConfirmed else StopRequest)
  , SlashCommand "/rewind"   True  True  "Rewind to an earlier turn (usage: /rewind <n>)" bothSurfaces (Rewind . firstToken)
  , SlashCommand "/restore"  True  True  "Restore a pre-edit snapshot (usage: /restore [n])" bothSurfaces (Restore . firstToken)
  , SlashCommand "/auth"     True  True  "Show provider key status (usage: /auth [check <name>])" bothSurfaces Auth
  , SlashCommand "/update"   True  True  "Compare with origin/main (usage: /update [pull])" bothSurfaces Update
  , SlashCommand "/reload-plugins" False True "Rescan user commands and plugins" bothSurfaces (\_ -> ReloadPlugins)
  , SlashCommand "/init"     False True  "Write an AGENTS.md skeleton for this project" bothSurfaces (\_ -> InitProject)
  , SlashCommand "/review"   True  True  "Send the working-tree diff to the model for review (usage: /review [path])" bothSurfaces Review
  , SlashCommand "/compress" True  True  "Compress the conversation history (alias of /compact; usage: /compress [focus])" bothSurfaces Compact
  , SlashCommand "/cd"       True  True  "Change the session working directory (usage: /cd <path>)" bothSurfaces ChangeDir
  , SlashCommand "/tools"    True  True  "List the scheduler's tools (usage: /tools [mode])" bothSurfaces ShowTools
  , SlashCommand "/permissions" False True "Show the permission rules" bothSurfaces (\_ -> ShowPermissions)
  , SlashCommand "/history"  False True  "Show recent input history" bothSurfaces (\_ -> ShowHistory)
  , SlashCommand "/about"    False True  "Version, workspace and runtime info" bothSurfaces (\_ -> About)
  , SlashCommand "/summary"  False True  "Summarize the conversation so far (alias of /recap)" bothSurfaces (\_ -> Recap)
  , SlashCommand "/forget"   True  True  "Delete remembered notes matching the text (usage: /forget <text>)" bothSurfaces Forget
  , SlashCommand "/ctx"      True  False "Show or set the context window size (usage: /ctx [tokens])" bothSurfaces SetCtx
  , SlashCommand "/effort"   True  False "Show or set the reasoning effort level (usage: /effort [level])" bothSurfaces Effort
  ]

-- | 参数候选表（批次四）：首词精确命中的命令在 palette 里给出参数补全。
-- 只收「静态可枚举」的参数——动态候选（会话 id、模型名）不在此列。
-- 键 = 命令名（含斜杠），值 = (参数词, 说明)。
commandArgs :: [(Text, [(Text, Text)])]
commandArgs =
  [ ("/export",  [ ("json", "JSON 格式"), ("md", "Markdown 格式") ])
  , ("/stash",   [ ("pop", "恢复最近草稿"), ("list", "列出暂存草稿") ])
  , ("/currency",[ ("set", "设置汇率（set CODE RATE）"), ("base", "基准币种（base CODE）") ])
  , ("/mode",    [ ("read-only", "只读"), ("ask", "询问"), ("auto", "自动")
                 , ("yolo", "YOLO"), ("plan", "计划") ])
  , ("/language",[ ("zh", "中文"), ("en", "English"), ("th", "ไทย") ])
  , ("/effort",  [ ("auto", "自动"), ("low", "低"), ("medium", "中"), ("high", "高") ])
  , ("/output-style", [ ("default", "默认"), ("concise", "简洁"), ("detailed", "详细") ])
  , ("/reasoning-language", [ ("auto", "自动"), ("zh-hans", "简体中文")
                            , ("zh-hant", "繁體中文"), ("en", "English")
                            , ("fr", "Français"), ("es", "Español"), ("ru", "Русский")
                            , ("th", "ไทย"), ("my", "မြန်မာ"), ("bo", "བོད་སྐད་"), ("ii", "ꆈꌠ") ])
  , ("/loop",    [ ("30s", "30 秒循环"), ("5m", "5 分钟循环")
                 , ("1h", "1 小时循环"), ("stop", "停止循环") ])
  ]
