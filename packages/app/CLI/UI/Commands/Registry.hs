{-# LANGUAGE OverloadedStrings #-}

-- | Single source of truth for slash commands, shared by the TUI quick
-- picker, the REPL command parser and the haskeline tab completion
-- (Phase 1.6 unification; cf. Reasonix slash_registry.go).
--
-- Pure module -- no IO, no brick -- so parsing/registry logic is
-- unit-testable.
module UI.Commands.Registry
  ( -- * Commands
    Command(..)
  , parseCommand
  , parseCommandWith
    -- * Settings keys
  , settingKeys
  , parseSettingValue
  , suggestSettingKey
  , formatSettings
    -- * Machine-readable schema
  , settingsSchemaJson
  , defaultFor
  , settingKeyDocs
    -- * Registry
  , SlashCommand(..)
  , slashRegistry
  , CommandGroup(..)
  , commandGroups
  , groupKey
  , groupTitle
  , groupOf
  , groupMembers
  , pickerItems
  , pickerItemsGrouped
  , completions
  , isKnownCommand
  , registryHelp
  , helpTextFor
  ) where

import Data.Aeson (Value(..), object, toJSON, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Data.List (minimumBy, sortOn)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import Core.Types (CLIConfig(..), defaultCLIConfig)
import UI.Commands.Registry.Table (SlashCommand(..), slashRegistry)
import UI.Commands.Registry.Settings
  ( defaultFor, formatSettings, parseSettingValue, settingKeyDocs, settingKeys
  , suggestSettingKey, settingsSchemaJson )
import UI.I18n (Lang(..), tr)
import UI.Render.Picker (PickerItem(..))

-- | Parsed REPL/TUI command.
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
  , (GInput,   [ "/attachments", "/clear-attachments", "/paste", "/vim", "/copy" ])
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
pickerItems :: Lang -> [PickerItem]
pickerItems lang =
  [ PickerItem (scCommand sc) (scCommand sc) (tr lang (scDesc sc))
  | sc <- slashRegistry
  , scPicker sc
  ]

-- | Picker items grouped by function, in display order; empty groups are
-- dropped and each group is sorted by command name.
pickerItemsGrouped :: Lang -> [(CommandGroup, [PickerItem])]
pickerItemsGrouped lang =
  [ (g, sortOn (T.toLower . piId) items)
  | g <- commandGroups
  , let items = [ PickerItem (scCommand sc) (scCommand sc) (tr lang (scDesc sc))
                | sc <- slashRegistry, scPicker sc, groupOf (scCommand sc) == g ]
  , not (null items)
  ]

-- | Tab-completion candidates (canonical command names).
completions :: [Text]
completions = map scCommand slashRegistry

-- | True when the leading word names a registered command (parameterised
-- commands match both bare and parameterised forms).
isKnownCommand :: Text -> Bool
isKnownCommand input =
  case T.words (T.strip input) of
    (w : _) | "/" `T.isPrefixOf` w ->
      any ((== w) . scCommand) slashRegistry
    _ -> False

-- | Help text generated from the registry, rendered in the active
-- language (descriptions are translated; command names never are).
registryHelp :: Lang -> Text
registryHelp lang = T.unlines $
  (tr lang "Commands:" : concatMap section commandGroups)
  ++ [""] ++ keySection
  where
    maxLen = maximum (map (T.length . scCommand) slashRegistry)
    section g = case sortOn scCommand [ sc | sc <- slashRegistry, groupOf (scCommand sc) == g ] of
      []   -> []
      scs  -> ("  " <> groupTitle lang g) : map (helpLine lang) scs
    helpLine l sc =
      let pad = T.replicate (maxLen - T.length (scCommand sc) + 2) " "
      in "  " <> scCommand sc <> pad <> tr l (scDesc sc)
    -- Keys are shell-local; stop is the only service-level command here.
    keySection =
      [ tr lang "Keys:"
      , "  Ctrl+Q        " <> tr lang "quit"
      , "  Ctrl+C        " <> tr lang "interrupt; press twice to quit"
      , "  Ctrl+D        " <> tr lang "quit when the prompt is empty"
      , "  /stop         " <> tr lang "stop the kernel and scheduler"
      ]

-- | Canonical setting keys (the fields of CLIConfig a user may persist).
helpTextFor :: Lang -> Text
helpTextFor lang = T.unlines $
  T.lines (registryHelp lang)
    ++ [ ""
       , tr lang "Quick picker:"
       , tr lang "  Type a slash prefix and press Enter to open the command menu;"
       , tr lang "  keep typing to filter, ↑/↓ to move, Enter to run, Esc to close."
       , ""
       , tr lang "Keys:"
       , tr lang "  PgUp / PgDn       Scroll messages"
       , tr lang "  Ctrl+Home / End   Jump to top / bottom"
       , tr lang "  Ctrl+O            Fold / expand thinking and tool cards"
       , tr lang "  Alt+↑ / Alt+↓     Move the tool-card focus"
       , tr lang "  Shift+Tab         Cycle permission posture"
       , tr lang "  Ctrl+Y            Toggle YOLO"
       , tr lang "  Esc Esc           Interrupt the running turn"
       , tr lang "  Ctrl+C            Interrupt · copy selection · clear draft · quit"
       , tr lang "  Ctrl+S            Submit the draft (same as Enter)"
       , tr lang "  Ctrl+Enter        Steer the running turn with the draft"
       , tr lang "  Ctrl+L            Clear the transcript view (history kept)"
       , tr lang "  Alt+V             Paste clipboard text"
       , tr lang "  Ctrl+G            Expand folded pastes"
       , tr lang "  Ctrl+B            Show / hide the sidebar"
       , tr lang "  Ctrl+X            Leader (b/p/m/s/,/?/i)"
       , tr lang "  Ctrl+Q / Ctrl+D   Quit"
       ]
