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
  | Rename Text
  | Tag Text
  | Home
  | Unknown Text
  | RunCustom Text Text   -- ^ user command name + arguments (~/.trha/commands)
  deriving (Show, Eq)

-- | A registered slash command.
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
  ]

-- | Parse a command from raw input.  Unknown slash commands become
-- 'Unknown' (never sent to the agent); anything else is a message.
-- | Functional groups shown in the command palette and @/help@.
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
               , "/rename", "/tag", "/delete", "/fork", "/branch" ])
  , (GHistory, [ "/export", "/transcript", "/stats", "/compact", "/clear"
               , "/cls", "/session-info", "/stash" ])
  , (GPlan,    [ "/plan", "/approve", "/deny", "/skip", "/reject", "/abandon"
               , "/goal", "/todo", "/tree", "/agents", "/graph", "/workflow"
               , "/loop", "/queue", "/steer" ])
  , (GModel,   [ "/model", "/models", "/provider", "/switch", "/fav", "/preset" ])
  , (GContext, [ "/context", "/usage", "/memory", "/remember", "/btw"
               , "/recap", "/retry", "/diff" ])
  , (GTools,   [ "/mcp", "/lsp", "/hooks", "/plugins", "/skills", "/doctor"
               , "/currency" ])
  , (GInput,   [ "/attachments", "/clear-attachments", "/paste", "/vim", "/copy" ])
  , (GAppearance, [ "/theme", "/language", "/reasoning-language"
                  , "/output-style", "/verbose" ])
  , (GSettings, [ "/mode", "/ask-timeout", "/settings" ])
  , (GHelp,    [ "/help", "/quit", "/exit", "/stop" ])
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
parseCommandBase input = case T.words (T.strip input) of
  []             -> SendMessage input
  ("/help" : _)  -> Help
  ("/quit" : _)  -> Quit
  ("/exit" : _)  -> Quit
  ("/stop" : "confirm" : _) -> StopConfirmed
  ("/stop" : _)  -> StopRequest
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
settingKeys :: [Text]
settingKeys = map (\(k, _, _) -> k) settingKeyDocs

-- | Per-key documentation: (key, value kind, English description key).
-- Mirrors the schema metadata found in reference CLIs (qwen-code
-- settingsSchema: each key carries a type and a description; deepseek
-- config-catalog documents every settable option with its contract).
settingKeyDocs :: [(Text, Text, Text)]
settingKeyDocs =
  [ ("host",      "text", "Server host for the orchestration scheduler")
  , ("port",      "int",  "Port of the orchestration scheduler")
  , ("model",     "text", "Default model name for new sessions")
  , ("provider",  "text", "Preferred model provider (empty = kernel default)")
  , ("token",     "text", "Bearer token used against the scheduler")
  , ("proxy",     "text", "Proxy for remote targets: unset = env | none | http://host:port (loopback is always direct)")
  , ("scheme",    "text", "Scheduler transport: https (default) | http")
  , ("maxTokens", "int",  "Maximum tokens per completion")
  , ("timeout",   "int",  "HTTP request timeout in milliseconds")
  , ("retries",   "int",  "Retry count for failed requests")
  , ("verbose",   "bool", "Verbose logging")
  , ("theme",     "text", "TUI theme: tokyo-night | light")
  , ("lang",      "text", "Interface language: zh | en")
  , ("reasoningLanguage", "text", "Language the model reasons in: auto = follow the interface language")
  , ("metrics",   "text", "Status-line metrics (comma separated keys)")
  , ("markdown",  "bool", "Render assistant replies as markdown")
  , ("timestamps","bool", "Show message timestamps")
  , ("hints",     "bool", "Show the footer key hints")
  , ("bell",      "bool", "Ring the bell when a reply completes")
  ]

-- | One-line key reference for /settings (localised kinds/labels).
settingKeyHelp :: Lang -> Text
settingKeyHelp lang = T.unlines
  [ tr lang "Available keys:"
  , T.unlines [ "  " <> k <> " (" <> tr lang kindDesc <> ")"
              | (k, kindDesc, _) <- settingKeyDocs ]
  ]

-- | Parse a textual value for a known key, starting from the given
-- (current effective) configuration.  Errors are already localised.
parseSettingValue :: Lang -> CLIConfig -> Text -> Text -> Either Text CLIConfig
parseSettingValue lang cfg key raw =
  case T.toLower (T.strip key) of
    "host"      -> Right cfg { configHost = T.strip raw }
    "port"      -> fmap (\p -> cfg { configPort = p }) (parseInt raw)
    "model"     -> Right cfg { configModel = T.strip raw }
    "provider"  -> Right cfg { configProvider = T.strip raw }
    "token"     -> Right cfg { configToken = T.strip raw }
    "proxy"     -> Right cfg { configProxy = T.strip raw }
    "scheme"    -> case T.toLower (T.strip raw) of
      "https" -> Right cfg { configScheme = "https" }
      "http"  -> Right cfg { configScheme = "http" }
      other   -> Left (tr lang "Value must be http or https: " <> other)
    "maxtokens" -> fmap (\n -> cfg { configMaxTokens = n }) (parseInt raw)
    "timeout"   -> fmap (\n -> cfg { configTimeout = n }) (parseInt raw)
    "retries"   -> fmap (\n -> cfg { configRetries = n }) (parseInt raw)
    "verbose"   -> fmap (\b -> cfg { configVerbose = b }) (parseBool raw)
    "markdown"  -> fmap (\b -> cfg { configMarkdown = b }) (parseBool raw)
    "timestamps" -> fmap (\b -> cfg { configTimestamps = b }) (parseBool raw)
    "hints"     -> fmap (\b -> cfg { configHints = b }) (parseBool raw)
    "bell"      -> fmap (\b -> cfg { configBell = b }) (parseBool raw)
    "theme"     -> Right cfg { configTheme = T.strip raw }
    "lang"      -> Right cfg { configLang = T.strip raw }
    "reasoninglanguage" -> Right cfg { configReasoningLanguage = T.strip raw }
    "metrics"   -> Right cfg { configMetrics = T.strip raw }
    _ -> Left (tr lang "Unknown setting key: " <> key
               <> maybe "" (\sugg -> " " <> tr lang "Did you mean: " <> sugg) (suggestSettingKey key))
  where
    parseInt v = case reads (T.unpack (T.strip v)) of
      [(n, "")] -> Right n
      _         -> Left (tr lang "Value must be a whole number: " <> v)
    parseBool v = case T.toLower (T.strip v) of
      "true"  -> Right True
      "false" -> Right False
      "1"     -> Right True
      "0"     -> Right False
      _       -> Left (tr lang "Value must be true or false: " <> v)

-- | Human-readable rendering of an effective configuration.
formatSettings :: Lang -> CLIConfig -> Text
formatSettings lang cfg = T.unlines
  [ tr lang "Settings:"
  , "  host        = " <> configHost cfg
  , "  port        = " <> T.pack (show (configPort cfg))
  , "  model       = " <> configModel cfg
  , "  provider    = " <> configProvider cfg
  , "  token       = " <> configToken cfg
  , "  maxTokens   = " <> T.pack (show (configMaxTokens cfg))
  , "  timeout     = " <> T.pack (show (configTimeout cfg))
  , "  retries     = " <> T.pack (show (configRetries cfg))
  , "  verbose     = " <> (if configVerbose cfg then "true" else "false")
  , "  markdown    = " <> (if configMarkdown cfg then "true" else "false")
  , "  timestamps  = " <> (if configTimestamps cfg then "true" else "false")
  , "  hints       = " <> (if configHints cfg then "true" else "false")
  , "  bell        = " <> (if configBell cfg then "true" else "false")
  , "  theme       = " <> configTheme cfg
  , "  lang        = " <> configLang cfg
  , "  reasoningLanguage = " <> configReasoningLanguage cfg
  , "  scheme      = " <> configScheme cfg
  , "  " <> tr lang "(effective: layered defaults < ~/.trha/settings.yaml < project)"
  , ""
  , T.strip (settingKeyHelp lang)
  ]

-- | Suggest the closest known key when the user mistypes one (edit
-- distance <= 2, like the reference CLI's typo help).  'Nothing' when no
-- key is close enough.
suggestSettingKey :: Text -> Maybe Text
suggestSettingKey key
  | T.null key = Nothing
  | otherwise = case hits of
      []  -> Nothing
      _   -> Just (fst (minimumBy (comparing snd) hits))
  where
    hits = [ (k, lev key k) | k <- settingKeys, k /= key, lev key k <= 2 ]

-- | Classic Levenshtein edit distance.
lev :: Text -> Text -> Int
lev a b = go (T.unpack a) (T.unpack b)
  where
    go [] ys = length ys
    go xs [] = length xs
    go (x : xs) (y : ys)
      | x == y = go xs ys
      | otherwise = 1 + minimum [ go xs ys, go (x : xs) ys, go xs (y : ys) ]

      | otherwise = 1 + minimum [ go xs ys, go (x : xs) ys, go xs (y : ys) ]

-- | Default textual value of a key (from 'defaultCLIConfig'), used to fill
-- the machine-readable schema.
defaultFor :: Text -> Text
defaultFor k = case k of
  "host"      -> configHost def
  "port"      -> T.pack (show (configPort def))
  "token"     -> configToken def
  "proxy"     -> configProxy def
  "scheme"    -> configScheme def
  "model"     -> configModel def
  "maxTokens" -> T.pack (show (configMaxTokens def))
  "timeout"   -> T.pack (show (configTimeout def))
  "retries"   -> T.pack (show (configRetries def))
  "verbose"   -> boolT (configVerbose def)
  "theme"     -> configTheme def
  "lang"      -> configLang def
  "reasoningLanguage" -> configReasoningLanguage def
  "metrics"   -> configMetrics def
  "markdown"  -> boolT (configMarkdown def)
  "timestamps" -> boolT (configTimestamps def)
  "hints"     -> boolT (configHints def)
  "bell"      -> boolT (configBell def)
  _           -> ""
  where
    def = defaultCLIConfig
    boolT True = "true"
    boolT False = "false"

-- | Machine-readable settings schema (config-catalog style): one row per
-- key with kind, English description and the default value.
settingsSchemaJson :: Text
settingsSchemaJson = TE.decodeUtf8 (BL.toStrict (Aeson.encode rows))
  where
    rows = [ object
               [ "key" .= k
               , "kind" .= kind
               , "description" .= desc
               , "default" .= defaultFor k
               ]
           | (k, kind, desc) <- settingKeyDocs
           ]
