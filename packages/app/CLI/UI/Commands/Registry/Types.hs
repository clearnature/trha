{-# LANGUAGE OverloadedStrings #-}

-- | 命令类型：@Command@（解析结果，执行侧按它分派）与 @CommandGroup@（帮助分组）。
--
-- 从 "UI.Commands.Registry" 下沉。Registry 与 Registry.Parser 都要用 Command，
-- 留任何一边都会成环。
module UI.Commands.Registry.Types
  ( Command(..)
  , CommandGroup(..)
  , commandGroups
  , groupKey
  , groupTitle
  , groupMembers
  , groupOf
  ) where

import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import UI.I18n (Lang(..), tr)

data Command
  = Help
  | Quit
  | StopRequest
  | StopConfirmed
  | Sessions
  | CreateSession
  | DeleteSession String
  | ShowSettings
  | SetSetting Text Text
  | SetLanguage (Maybe Text)
  | ShowDiff
  | ShowContext
  | Doctor
  | ShowMemory
  | ShowStats
  | ShowUsage
  | Compact Text
  | ShowAttachments
  | ClearAttachments
  | ShowMcp
  | ShowLsp
  | ShowPresets
  | ShowHooks
  | Paste Text
  | EditPrompt
  | OutputStyle (Maybe Text)
  | SessionInfoView
  | TranscriptView
  | Retry
  | Btw Text
  | Workspace (Maybe Text)
  | Recap
  | Queue (Maybe Text)
  | Steer Text
  | Fork Text
  | Branch
  | GoalView
  | SwitchProvider (Maybe Text)
  | Loop Text
  | Graph
  | Workflow Text
  | Currency Text
  | Cls
  | AskTimeout (Maybe Text)
  | ReasoningLanguage (Maybe Text)
  | Remember Text
  | Models
  | SelectModel Text
  | ShowModel
  | Providers
  | Plan Text
  | Approve
  | Deny
  | DenyWith Text
  | SkipStep
  | RejectStep
  | AbandonPlan
  | Plugins
  | ResumeList
  | ResumeSelect String
  | SendMessage Text
  | Clear
  | Status
  | Export Text
  | StashDraft Text
  | Fav Text
  | Skills
  | SetTheme Text
  | SetMouseCapture (Maybe Bool)
  | Effort Text
  | SetCtx Text
  | Mode Text
  | CopyLast
  | Verbose
  | Todo
  | Tree
  | Agents
  | Sandbox
  | Rename Text
  | Tag Text
  | Home
  | RunShell Text        -- ^ @/shell <cmd>@: run a local command, like @!cmd@
  | Unknown Text
  | RunCustom Text Text   -- ^ user command name + arguments (~/.trha/commands)
  | Rewind Text           -- ^ @/rewind <n>@: fork back to turn @n@ and switch to it
  | Restore Text          -- ^ @/restore [n]@: restore a pre-edit snapshot from ~/.trha/file-history
  | Auth Text             -- ^ @/auth [check <name>]@: provider key status
  | Update Text           -- ^ @/update [pull]@: compare with origin/main, optionally pull
  | ReloadPlugins         -- ^ @/reload-plugins@: rescan user commands and report plugin hot-reload state
  | InitProject           -- ^ @/init@: write an AGENTS.md skeleton when the project has none
  | Review Text           -- ^ @/review [path]@: send the working-tree diff to the model for review
  | ChangeDir Text        -- ^ @/cd <path>@: change the session working directory
  | ShowTools Text        -- ^ @/tools [mode]@: list the scheduler's tools
  | ShowPermissions       -- ^ @/permissions@: show the permission rules
  | ShowHistory           -- ^ @/history@: recent input history
  | About                 -- ^ @/about@: version, workspace and runtime info
  | Forget Text           -- ^ @/forget <text>@: delete matching remembered notes
  deriving (Show, Eq)

-- | A registered slash command.
data CommandGroup
  = GSession | GHistory | GPlan | GModel | GContext
  | GTools | GInput | GAppearance | GSettings | GHelp
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Display order (most used first).
commandGroups :: [CommandGroup]
commandGroups = [minBound .. maxBound]

-- | Stable English id, also the palette section id.
groupKey :: CommandGroup -> Text
groupKey g = case g of
  GSession    -> "session"
  GHistory    -> "history"
  GPlan       -> "plan"
  GModel      -> "model"
  GContext    -> "context"
  GTools      -> "tools"
  GInput      -> "input"
  GAppearance -> "appearance"
  GSettings   -> "settings"
  GHelp       -> "help"

-- | Bilingual heading: localised name + English id (e.g. "会话 session").
-- Falls back to the bare id when the dictionary has no translation.
groupTitle :: Lang -> CommandGroup -> Text
groupTitle lang g =
  let key = groupKey g
      localised = tr lang key
  in if localised == key then key else localised <> " " <> key

-- | Membership table.  Every command in 'slashRegistry' appears exactly
-- once; the spec pins that so a new command cannot silently fall out of
-- the palette.
groupMembers :: [(CommandGroup, [Text])]
groupMembers =
  [ (GSession, [ "/new", "/sessions", "/status", "/home", "/resume"
               , "/rename", "/tag", "/delete", "/fork", "/branch"
               , "/rewind", "/restore", "/cd" ])
  , (GHistory, [ "/export", "/transcript", "/stats", "/compact", "/clear"
               , "/cls", "/session-info", "/stash", "/compress", "/history"
               , "/summary" ])
  , (GPlan,    [ "/plan", "/approve", "/deny", "/skip", "/reject", "/abandon"
               , "/goal", "/todo", "/tree", "/agents", "/graph", "/workflow"
               , "/loop", "/queue", "/steer" ])
  , (GModel,   [ "/model", "/models", "/provider", "/switch", "/fav", "/preset"
               , "/auth", "/effort" ])
  , (GContext, [ "/context", "/usage", "/memory", "/remember", "/btw", "/workspace"
               , "/recap", "/retry", "/diff", "/forget", "/ctx" ])
  , (GTools,   [ "/shell", "/mcp", "/lsp", "/hooks", "/plugins", "/skills", "/doctor"
               , "/currency", "/update", "/reload-plugins", "/init", "/review"
               , "/tools", "/permissions" ])
  , (GInput,   [ "/attachments", "/clear-attachments", "/paste", "/vim", "/copy", "/mouse" ])
  , (GAppearance, [ "/theme", "/language", "/reasoning-language"
                  , "/output-style", "/verbose" ])
  , (GSettings, [ "/mode", "/sandbox", "/ask-timeout", "/settings" ])
  , (GHelp,    [ "/help", "/quit", "/exit", "/stop", "/about" ])
  ]

-- | Group of a command; unknown names fall back to 'GSession'.
groupOf :: Text -> CommandGroup
groupOf cmd = fromMaybe GSession
  (listToMaybe [ g | (g, cs) <- groupMembers, cmd `elem` cs ])

-- | Parse a command without user-defined commands.
