{-# LANGUAGE OverloadedStrings #-}

-- | 命令解析：把一行输入切成 @Command@。
--
-- 从 "UI.Commands.Registry" 拆出。解析只依赖 Types 与 Registry.Table
-- （命令名清单），不依赖派生的 picker/help 视图。
module UI.Commands.Registry.Parser
  ( parseCommand
  , parseCommandWith
  , parseCommandBase
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import UI.Commands.Registry.Types
import UI.Commands.Registry.Table (slashRegistry, SlashCommand(..))

parseCommand :: Text -> Command
parseCommand = parseCommandWith []

-- | Parse with user-defined command names (@~/.trha/commands@) recognised
-- first; the rest falls through to the built-in registry.
parseCommandWith :: [Text] -> Text -> Command
parseCommandWith custom input =
  case T.words (T.strip input) of
    (w : args)
      | Just name <- T.stripPrefix "/" w
      , name `elem` custom -> RunCustom name (T.unwords args)
    _ -> parseCommandBase input

parseCommandBase :: Text -> Command
-- @/shell@ keeps the raw argument text: re-splitting it with 'T.words' would
-- collapse the spaces inside quotes (e.g. @/shell echo "a  b"@).
parseCommandBase input
  | Just rest <- T.stripPrefix "/shell" (T.strip input)
  , T.null rest || " " `T.isPrefixOf` rest = RunShell (T.strip rest)
parseCommandBase input = case T.words (T.strip input) of
  []             -> SendMessage input
  ("/help" : _)  -> Help
  ("/quit" : _)  -> Quit
  ("/exit" : _)  -> Quit
  ("/stop" : "confirm" : _) -> StopConfirmed
  ("/stop" : _)  -> StopRequest
  ("/rewind" : n : _) -> Rewind n
  ("/rewind" : _) -> Rewind ""
  ("/restore" : n : _) -> Restore n
  ("/restore" : _) -> Restore ""
  ("/auth" : args) -> Auth (T.unwords args)
  ("/update" : args) -> Update (T.unwords args)
  ("/reload-plugins" : _) -> ReloadPlugins
  ("/compress" : focus) -> Compact (T.unwords focus)
  ("/init" : _) -> InitProject
  ("/review" : args) -> Review (T.unwords args)
  ("/cd" : args) -> ChangeDir (T.unwords args)
  ("/tools" : args) -> ShowTools (T.unwords args)
  ("/permissions" : _) -> ShowPermissions
  ("/history" : _) -> ShowHistory
  ("/about" : _) -> About
  ("/summary" : _) -> Recap
  ("/forget" : args) -> Forget (T.unwords args)
  ("/ctx" : args) -> SetCtx (T.unwords args)
  ("/effort" : args) -> Effort (T.unwords args)
  ("/sessions" : _) -> Sessions
  ("/new" : _)   -> CreateSession
  ("/delete" : [])   -> DeleteSession ""
  ("/delete" : sid : _) -> DeleteSession (T.unpack sid)
  ("/models" : _) -> Models
  ("/provider" : _) -> Providers
  ("/model" : [])  -> ShowModel
  ("/model" : name : _) | not (T.null name) -> SelectModel name
  ("/plan" : []) -> Plan ""
  ("/plan" : args) -> Plan (T.unwords args)
  ("/plugins" : _)  -> Plugins
  ("/resume" : [])   -> ResumeList
  ("/resume" : arg : _) -> ResumeSelect (T.unpack arg)
  ("/approve" : _) -> Approve
  ("/deny" : args) | not (null args) -> DenyWith (T.unwords args)
  ("/deny" : _)   -> Deny
  ("/skip" : _)    -> SkipStep
  ("/reject" : _)  -> RejectStep
  ("/abandon" : _) -> AbandonPlan
  ("/diff" : _) -> ShowDiff
  ("/context" : _) -> ShowContext
  ("/doctor" : _) -> Doctor
  ("/memory" : _) -> ShowMemory
  ("/stats" : _) -> ShowStats
  ("/usage" : _) -> ShowUsage
  ("/compact" : focus) -> Compact (T.unwords focus)
  ("/attachments" : _) -> ShowAttachments
  ("/clear-attachments" : _) -> ClearAttachments
  ("/mcp" : _) -> ShowMcp
  ("/lsp" : _) -> ShowLsp
  ("/preset" : _) -> ShowPresets
  ("/hooks" : _) -> ShowHooks
  ("/paste" : text) -> Paste (T.unwords text)
  ("/vim" : _) -> EditPrompt
  ("/output-style" : []) -> OutputStyle Nothing
  ("/output-style" : name : _) -> OutputStyle (Just name)
  ("/session-info" : _) -> SessionInfoView
  ("/transcript" : _) -> TranscriptView
  ("/retry" : _) -> Retry
  ("/btw" : question) -> Btw (T.unwords question)
  ("/workspace" : args) ->
    Workspace (case filter (not . T.null) args of
                 [] -> Nothing
                 ws -> Just (T.unwords ws))
  ("/recap" : _) -> Recap
  ("/queue" : []) -> Queue Nothing
  ("/queue" : text) -> Queue (Just (T.unwords text))
  ("/steer" : prompt) -> Steer (T.unwords prompt)
  ("/fork" : title) -> Fork (T.unwords title)
  ("/branch" : _) -> Branch
  ("/goal" : _) -> GoalView
  ("/switch" : []) -> SwitchProvider Nothing
  ("/switch" : name : _) -> SwitchProvider (Just name)
  ("/loop" : args) -> Loop (T.unwords args)
  ("/graph" : _) -> Graph
  ("/workflow" : args) -> Workflow (T.unwords args)
  ("/currency" : args) -> Currency (T.unwords args)
  ("/cls" : _) -> Cls
  ("/ask-timeout" : []) -> AskTimeout Nothing
  ("/ask-timeout" : n : _) -> AskTimeout (Just n)
  ("/reasoning-language" : []) -> ReasoningLanguage Nothing
  ("/reasoning-language" : l : _) -> ReasoningLanguage (Just l)
  ("/remember" : text) -> Remember (T.unwords text)
  ("/language" : []) -> SetLanguage Nothing
  ("/language" : code : _) -> SetLanguage (Just code)
  ("/settings" : []) -> ShowSettings
  ("/settings" : key : rest) -> SetSetting key (T.unwords rest)
  ("/settings" : _) -> SetSetting "" ""
  ("/clear" : _)  -> Clear
  ("/status" : _) -> Status
  ("/home" : _) -> Home
  ("/export" : args) -> Export (T.unwords args)
  ("/stash" : args) -> StashDraft (T.unwords args)
  ("/fav" : args) -> Fav (T.unwords args)
  ("/skills" : _) -> Skills
  ("/theme" : args) -> SetTheme (T.unwords args)
  ("/mouse" : args) -> SetMouseCapture (case map T.toLower args of
      ["on"]  -> Just True
      ["off"] -> Just False
      _       -> Nothing)
  ("/mode" : args) -> Mode (T.unwords args)
  ("/copy" : _) -> CopyLast
  ("/verbose" : _) -> Verbose
  ("/todo" : _) -> Todo
  ("/tree" : _) -> Tree
  ("/agents" : _) -> Agents
  ("/sandbox" : _) -> Sandbox
  ("/rename" : args) -> Rename (T.unwords args)
  ("/tag" : args) -> Tag (T.unwords args)
  (w : _)
    | "/" `T.isPrefixOf` w -> Unknown w
  _ -> SendMessage input

-- | Items offered by the TUI quick picker (registry order), with the
-- description rendered in the active language.
