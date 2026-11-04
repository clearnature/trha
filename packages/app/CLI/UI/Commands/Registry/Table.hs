{-# LANGUAGE OverloadedStrings #-}

-- | 斜杠命令定义表：@SlashCommand@ 的字段与唯一的 @slashRegistry@ 列表。
--
-- 从 "UI.Commands.Registry" 拆出。这是**纯数据**——加一个命令只需在这里加一行
-- （解析分支在 Registry，执行在 UI.Commands.* 领域模块，文案在 UI.I18n.Zh）。
module UI.Commands.Registry.Table
  ( SlashCommand(..)
  , slashRegistry
  ) where

import Data.Text (Text)

data SlashCommand = SlashCommand
  { scCommand :: Text   -- ^ canonical name, e.g. @"/model"@
  , scHasArg  :: Bool   -- ^ requires (or accepts) a parameter
  , scPicker  :: Bool   -- ^ offer in the TUI quick picker (runnable as-is)
  , scDesc    :: Text   -- ^ one-line help text
  } deriving (Show, Eq)

-- | The command registry -- the single list every UI derives its
-- candidates from.
slashRegistry :: [SlashCommand]
slashRegistry =
  [ SlashCommand "/help"     False True  "Show this help"
  , SlashCommand "/model"    True  True  "Show or set the current model"
  , SlashCommand "/models"   False True  "List available models"
  , SlashCommand "/provider" False True  "Choose the model provider"
  , SlashCommand "/new"      False True  "Create a new session"
  , SlashCommand "/sessions" False True  "List all sessions"
  , SlashCommand "/status"   False True  "Show current session/model status"
  , SlashCommand "/home"     False True  "Back to the Home screen (recent sessions)"
  , SlashCommand "/stash"    True  True  "Park or restore a draft (usage: /stash [pop|list])"
  , SlashCommand "/fav"      True  True  "Pin/unpin a favourite model (usage: /fav [model])"
  , SlashCommand "/skills"   False True  "List discovered skills"
  , SlashCommand "/theme"    True  True  "List or switch the colour theme (usage: /theme [name])"
  , SlashCommand "/mode"     True  True  "Cycle or set the permission posture (usage: /mode [read-only|ask|auto|yolo|plan])"
  , SlashCommand "/copy"     False True  "Copy the last assistant message"
  , SlashCommand "/verbose"  False True  "Toggle verbose tool output"
  , SlashCommand "/todo"     False True  "Show team tasks"
  , SlashCommand "/tree"     False True  "Show the agent session tree"
  , SlashCommand "/agents"   False True  "Show agent sessions in a dialog"
  , SlashCommand "/sandbox"  False True  "SandBox: toggle enforcement and tune policy/network"
  , SlashCommand "/rename"   True  True  "Rename the active session (usage: /rename <title>)"
  , SlashCommand "/tag"      True  True  "Set session tags (usage: /tag <tag> [tag...])"
  , SlashCommand "/export"   True  True  "Export the transcript (usage: /export [json|md] [path])"
  , SlashCommand "/settings" True  True  "View or edit settings (usage: /settings [key value])"
  , SlashCommand "/language" True  True  "Switch the CLI language (usage: /language [code])"
  , SlashCommand "/diff"     False True  "Show the working-tree diff"
  , SlashCommand "/context"  False True  "Show context-window usage"
  , SlashCommand "/doctor"   False True  "Check scheduler, provider, fonts and settings"
  , SlashCommand "/memory"   False True  "Show remembered notes (~/.trha/memories)"
  , SlashCommand "/remember" True  True  "Append a note to memory (usage: /remember <text>)"
  , SlashCommand "/shell"    True  True  "Run a local shell command (usage: /shell <cmd>)"
  , SlashCommand "/stats"    False True  "Show transcript statistics for this session"
  , SlashCommand "/usage"    False True  "Show account balance and the active model"
  , SlashCommand "/compact"  True  True  "Compact the conversation history (usage: /compact [focus])"
  , SlashCommand "/attachments" False True "List queued clipboard attachments"
  , SlashCommand "/clear-attachments" False True "Drop all queued clipboard attachments"
  , SlashCommand "/mcp"      False True  "Show MCP server status"
  , SlashCommand "/lsp"      False True  "Show LSP server status"
  , SlashCommand "/preset"   False True  "List built-in provider presets"
  , SlashCommand "/hooks"    False True  "List configured hooks"
  , SlashCommand "/paste"    True  True  "Attach a clipboard image (usage: /paste [text])"
  , SlashCommand "/vim"      False True  "Edit the next message in $EDITOR"
  , SlashCommand "/output-style" True True "Show or set the reply style (default|concise|detailed)"
  , SlashCommand "/session-info" False True "Show session details (mode, goal, todos)"
  , SlashCommand "/transcript" False True "Replay the current session transcript"
  , SlashCommand "/retry"    False True  "Retry the last turn exactly"
  , SlashCommand "/btw"      True  True  "Ask a side question without changing the conversation"
  , SlashCommand "/workspace" True True  "Show or change the session workspace (human-only; agents cannot reach it)"
  , SlashCommand "/recap"    False True  "Summarize the conversation so far"
  , SlashCommand "/queue"    True  True  "Queue a message for after this turn (usage: /queue [message])"
  , SlashCommand "/steer"    True  True  "Steer the running turn (usage: /steer <prompt>)"
  , SlashCommand "/fork"     True  True  "Fork this session into a child (usage: /fork [title])"
  , SlashCommand "/branch"   False True  "Fork just before the last user turn"
  , SlashCommand "/goal"     False True  "Show the session goal and todo count"
  , SlashCommand "/switch"   True  True  "Switch the active provider (usage: /switch [name])"
  , SlashCommand "/loop"     True  True  "Run a prompt on an interval (usage: /loop <30s|5m|1h> <prompt> | /loop stop)"
  , SlashCommand "/graph"    False True  "Show the session tree and tool-call counts"
  , SlashCommand "/workflow" True  True  "Run a workflow template (usage: /workflow [name] [input])"
  , SlashCommand "/currency" True  True  "Show or edit manual currency rates (usage: /currency [set CODE RATE | base CODE])"
  , SlashCommand "/cls"      False True  "Clear the transcript view (history is kept)"
  , SlashCommand "/ask-timeout" True True "Show or set the approval wait in seconds (usage: /ask-timeout [seconds])"
  , SlashCommand "/reasoning-language" True True "Show or set the reasoning language (usage: /reasoning-language [auto|zh-Hans|en])"
  , SlashCommand "/clear"    False True  "Clear message history"
  , SlashCommand "/delete"   True  False "Delete a session (usage: /delete <id>)"
  , SlashCommand "/plan"     True  False "Submit a plan for approval (usage: /plan <what to do>)"
  , SlashCommand "/plugins"  False True  "List registered orchestration plugins"
  , SlashCommand "/resume"   False True  "List or resume local sessions (usage: /resume [n])"
  , SlashCommand "/approve"  False True  "Approve the pending plan"
  , SlashCommand "/deny"     False True  "Deny the pending plan (usage: /deny [reason])"
  , SlashCommand "/skip"     False True  "Skip the pending plan step"
  , SlashCommand "/reject"   False True  "Reject the pending plan step (halts the plan)"
  , SlashCommand "/abandon"  False True  "Abandon the running plan"
  , SlashCommand "/quit"     False True  "Exit the application"
  , SlashCommand "/exit"     False True  "Exit the application (alias)"
  , SlashCommand "/stop"     True  False "Stop the kernel and scheduler (usage: /stop confirm)"
  , SlashCommand "/rewind"   True  True  "Rewind to an earlier turn (usage: /rewind <n>)"
  , SlashCommand "/restore"  True  True  "Restore a pre-edit snapshot (usage: /restore [n])"
  , SlashCommand "/auth"     True  True  "Show provider key status (usage: /auth [check <name>])"
  , SlashCommand "/update"   True  True  "Compare with origin/main (usage: /update [pull])"
  , SlashCommand "/reload-plugins" False True "Rescan user commands and plugins"
  , SlashCommand "/init"     False True  "Write an AGENTS.md skeleton for this project"
  , SlashCommand "/review"   True  True  "Send the working-tree diff to the model for review (usage: /review [path])"
  , SlashCommand "/compress" True  True  "Compress the conversation history (alias of /compact; usage: /compress [focus])"
  , SlashCommand "/cd"       True  True  "Change the session working directory (usage: /cd <path>)"
  , SlashCommand "/tools"    True  True  "List the scheduler's tools (usage: /tools [mode])"
  , SlashCommand "/permissions" False True "Show the permission rules"
  , SlashCommand "/history"  False True  "Show recent input history"
  , SlashCommand "/about"    False True  "Version, workspace and runtime info"
  , SlashCommand "/summary"  False True  "Summarize the conversation so far (alias of /recap)"
  , SlashCommand "/forget"   True  True  "Delete remembered notes matching the text (usage: /forget <text>)"
  , SlashCommand "/ctx"      True  False "Show or set the context window size (usage: /ctx [tokens])"
  , SlashCommand "/effort"   True  False "Show or set the reasoning effort level (usage: /effort [level])"
  ]

-- | Parse a command from raw input.  Unknown slash commands become
-- 'Unknown' (never sent to the agent); anything else is a message.
-- | Functional groups shown in the command palette and @/help@.
