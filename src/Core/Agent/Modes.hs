{-# LANGUAGE OverloadedStrings #-}

-- | Agent modes control which tools, persona, and capabilities are available.
-- Ported from deepseek-harness's standard/ptc/minimal/cordis presets.
module Core.Agent.Modes
  ( -- * Types
    AgentMode(..)
  , ModeConfig(..)
  , ToolDef(..)
  , PersonaConfig(..)
  , CompactionConfig(..)
  , DelegationConfig(..)
  , PTCConfig(..)
    -- * Operations
  , getModeConfig
  , availableModes
  , modeToText
  , textToMode
  , toolsForMode
  , hasTool
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Available agent modes (matching deepseek-harness presets)
data AgentMode
  = Standard    -- ^ Full coding agent with all tools
  | PTC         -- ^ Program-the-code: model writes a program, one call multi-tool
  | Minimal     -- ^ Lightweight: basic tools only, no compaction or plan
  | Cordis      -- ^ Base layer: user composes their own tool set
  deriving (Show, Eq, Enum, Bounded)

-- | Tool definition
data ToolDef = ToolDef
  { toolName        :: Text
  , toolDescription :: Text
  , toolEnabled     :: Bool
  } deriving (Show, Eq)

-- | Persona configuration
data PersonaConfig = PersonaConfig
  { personaEnabled   :: Bool
  , personaTemplate  :: Text
  , personaMaxBytes  :: Int
  } deriving (Show, Eq)

-- | Compaction configuration
data CompactionConfig = CompactionConfig
  { compactionEnabled       :: Bool
  , compactionPrunerEnabled :: Bool
  , compactionThreshold     :: Int   -- ^ Chars before compaction triggers
  , compactionHeadChars     :: Int   -- ^ Keep this many chars from head
  , compactionTailChars     :: Int   -- ^ Keep this many chars from tail
  } deriving (Show, Eq)

-- | Delegation configuration
data DelegationConfig = DelegationConfig
  { delegationEnabled      :: Bool
  , delegationForkEnabled  :: Bool
  , delegationRalphEnabled :: Bool
  , delegationMaxRounds    :: Int
  } deriving (Show, Eq)

-- | PTC-specific configuration
data PTCConfig = PTCConfig
  { ptcEnabled       :: Bool
  , ptcLanguage      :: Text   -- ^ "typescript" or "python"
  , ptcDescription   :: Text
  } deriving (Show, Eq)

-- | Full mode configuration
data ModeConfig = ModeConfig
  { modeName          :: Text
  , modeDescription   :: Text
  , modeTools         :: [ToolDef]
  , modePersona       :: PersonaConfig
  , modeCompaction    :: CompactionConfig
  , modeDelegation    :: DelegationConfig
  , modePTC           :: PTCConfig
  , modeHasPlan       :: Bool
  , modeHasTodo       :: Bool
  , modeHasWebSearch  :: Bool
  , modeHasShell      :: Bool
  , modeMaxTokens     :: Int
  , modeContextSize   :: Int
  } deriving (Show, Eq)

-- | All tools available in the system (40 tools, matching deepseek-harness)
allTools :: [ToolDef]
allTools =
  [ -- Shell & Filesystem
    ToolDef "bash"              "Execute shell commands in a bash shell"           True
  , ToolDef "read"              "Read a file (with optional offset/limit)"         True
  , ToolDef "write"             "Write a file (create or overwrite)"               True
  , ToolDef "edit"              "Edit a file with exact string find/replace"       True
  , ToolDef "grep"              "Search file contents with ripgrep regex"          True
  , ToolDef "glob"              "Find files by glob pattern"                       True
  , ToolDef "web_search"        "Search the web (1-4 queries)"                     True
  , ToolDef "web_fetch"         "Fetch a URL and return text/markdown"             True
  , ToolDef "describe_image"    "OCR/analyze an image file or URL"                 True

    -- Agent & Delegation
  , ToolDef "subagent"          "Delegate task to a background sub-agent"          True
  , ToolDef "subagent_fork"     "Fork current conversation to a sub-agent"         True
  , ToolDef "workflow"          "Run a multi-step workflow across sub-agents"       True
  , ToolDef "ralph"             "Fresh-agent iterative loop toward an objective"    True
  , ToolDef "ask_user"          "Ask the user a question"                           True

    -- Session & State
  , ToolDef "todo"              "Write/update structured task list"                 True
  , ToolDef "plan"              "Enter plan mode (non-mutating exploration)"        True
  , ToolDef "checkpoint"        "Create a unified workspace/session checkpoint"     True
  , ToolDef "memory_remember"   "Persist a fact to cross-session memory vault"      True
  , ToolDef "memory_recall"     "Search cross-session memory vault"                 True
  , ToolDef "memory_forget"     "Delete entries from memory vault"                  True

    -- PTC Mode
  , ToolDef "run_code"          "PTC: execute model-authored program against tools" True

    -- Skills & Plugins
  , ToolDef "skill"             "Load and execute a skill by name"                  True

    -- Remote & SSH
  , ToolDef "remote_host_add"   "Register a remote compute host"                   True
  , ToolDef "remote_exec"       "Execute a short command on a remote host"          True
  , ToolDef "remote_run"        "Submit a background job to a remote host"          True
  , ToolDef "remote_status"     "Check remote job status"                           True
  , ToolDef "remote_pull"       "Pull remote job output to local"                   True
  , ToolDef "remote_cancel"     "Cancel a remote job"                               True
  , ToolDef "remote_logs"       "View remote job logs"                              True
  , ToolDef "ssh_exec"          "Execute command on configured SSH host"            True
  , ToolDef "ssh_download"      "Download file from SSH host"                       True
  , ToolDef "ssh_upload"        "Upload file to SSH host"                           True
  , ToolDef "ssh_tunnel"        "Manage local port-forward tunnels to SSH host"     True
  , ToolDef "ssh_cluster"       "Run command concurrently across SSH hosts"         True

    -- Browser & Pilot
  , ToolDef "pilot_open"        "Open URL in controlled browser"                    True
  , ToolDef "pilot_click"       "Click element in browser"                          True
  , ToolDef "pilot_type"        "Type text into browser input"                      True
  , ToolDef "pilot_snapshot"    "Read browser page as text snapshot"                 True
  , ToolDef "pilot_screenshot"  "Capture browser page screenshot"                   True

    -- GitHub
  , ToolDef "github_repo"       "Get GitHub repository metadata"                    True
  , ToolDef "github_issues"     "List GitHub issues"                                True
  , ToolDef "github_prs"        "List GitHub pull requests"                         True
  , ToolDef "github_create_issue" "Create a GitHub issue"                           True
  , ToolDef "github_create_pr"  "Create a GitHub pull request"                      True
  , ToolDef "github_search"     "Search GitHub repositories/code/issues"            True

    -- Research & Deep Read
  , ToolDef "deepread"          "Deep-read books/articles/PDFs with analysis"       True

    -- Compressor (context management)
  , ToolDef "compressor_retrieve" "Retrieve compressed conversation text"           True

    -- Artifacts (versioned outputs)
  , ToolDef "artifact_save"     "Save analysis/chart/data as versioned artifact"    True
  , ToolDef "artifact_list"     "List all versioned artifacts"                      True
  , ToolDef "artifact_show"     "Show artifact metadata and provenance"             True

    -- Background Jobs
  , ToolDef "job_output"        "Read background job output"                        True
  , ToolDef "job_kill"          "Cancel a running background job"                   True

    -- Double-check Discipline
  , ToolDef "doublecheck_spec"  "Record grilled requirements spec"                  True
  , ToolDef "doublecheck_report" "Generate delivery proof report"                   True

    -- Research Loop
  , ToolDef "research_init"     "Initialize research project"                       True
  , ToolDef "research_hypothesis" "Register a research hypothesis"                  True
  , ToolDef "research_experiment" "Register an experiment"                          True
  , ToolDef "research_findings" "Record experiment findings"                        True

    -- Logic Verification
  , ToolDef "logicprobe_verify" "Run executable state-machine verification"         True
  ]

-- | Standard mode: full coding agent
standardConfig :: ModeConfig
standardConfig = ModeConfig
  { modeName        = "standard"
  , modeDescription = "Full coding agent with all tools and capabilities"
  , modeTools       = filter (\t -> toolName t /= "run_code") allTools
  , modePersona     = PersonaConfig
    { personaEnabled  = True
    , personaTemplate = "You are a coding agent powered by the {{model}} model.\nYour working directory is {{cwd}}."
    , personaMaxBytes = 65536
    }
  , modeCompaction  = CompactionConfig
    { compactionEnabled       = True
    , compactionPrunerEnabled = True
    , compactionThreshold     = 8192
    , compactionHeadChars     = 4096
    , compactionTailChars     = 1024
    }
  , modeDelegation  = DelegationConfig
    { delegationEnabled      = True
    , delegationForkEnabled  = True
    , delegationRalphEnabled = True
    , delegationMaxRounds    = 64
    }
  , modePTC         = PTCConfig False "" ""
  , modeHasPlan     = True
  , modeHasTodo     = True
  , modeHasWebSearch = True
  , modeHasShell    = True
  , modeMaxTokens   = 8192
  , modeContextSize = 131072
  }

-- | PTC mode: program-the-code
ptcConfig :: ModeConfig
ptcConfig = ModeConfig
  { modeName        = "ptc"
  , modeDescription = "Program-the-code: model writes a program, one call multi-tool"
  , modeTools       = filter (\t -> toolName t `notElem` ["workflow", "todo", "plan"]) allTools
  , modePersona     = PersonaConfig
    { personaEnabled  = True
    , personaTemplate = "You are a coding agent powered by the {{model}} model.\nYour working directory is {{cwd}}.\n\n`run_code` is the only tool you can call directly — a tool call naming any other tool fails.\nReach every tool the SDK declares below from inside the program."
    , personaMaxBytes = 65536
    }
  , modeCompaction  = CompactionConfig
    { compactionEnabled       = True
    , compactionPrunerEnabled = True
    , compactionThreshold     = 8192
    , compactionHeadChars     = 4096
    , compactionTailChars     = 1024
    }
  , modeDelegation  = DelegationConfig
    { delegationEnabled      = True
    , delegationForkEnabled  = True
    , delegationRalphEnabled = True
    , delegationMaxRounds    = 64
    }
  , modePTC         = PTCConfig
    { ptcEnabled     = True
    , ptcLanguage    = "typescript"
    , ptcDescription = "Execute a TypeScript program against the available tools. "
        <> "Takes `code` (body of an async function) and `description`. "
        <> "Call tools as `await tools.name(args)`. Only what you print or return is output."
    }
  , modeHasPlan     = False
  , modeHasTodo     = False
  , modeHasWebSearch = True
  , modeHasShell    = True
  , modeMaxTokens   = 16384
  , modeContextSize = 131072
  }

-- | Minimal mode: lightweight
minimalConfig :: ModeConfig
minimalConfig = ModeConfig
  { modeName        = "minimal"
  , modeDescription = "Lightweight: basic tools only, no compaction or plan"
  , modeTools       = filter (\t -> toolName t `elem`
    [ "bash", "read", "write", "grep", "glob", "edit"
    , "web_fetch", "describe_image"
    , "ask_user"
    ]) allTools
  , modePersona     = PersonaConfig False "" 0
  , modeCompaction  = CompactionConfig False False 0 0 0
  , modeDelegation  = DelegationConfig False False False 0
  , modePTC         = PTCConfig False "" ""
  , modeHasPlan     = False
  , modeHasTodo     = False
  , modeHasWebSearch = False
  , modeHasShell    = True
  , modeMaxTokens   = 4096
  , modeContextSize = 65536
  }

-- | Cordis mode: base layer
cordisConfig :: ModeConfig
cordisConfig = ModeConfig
  { modeName        = "cordis"
  , modeDescription = "Base layer: user composes their own tool set"
  , modeTools       = []  -- User adds what they need
  , modePersona     = PersonaConfig False "" 0
  , modeCompaction  = CompactionConfig
    { compactionEnabled       = True
    , compactionPrunerEnabled = True
    , compactionThreshold     = 8192
    , compactionHeadChars     = 4096
    , compactionTailChars     = 1024
    }
  , modeDelegation  = DelegationConfig
    { delegationEnabled      = True
    , delegationForkEnabled  = True
    , delegationRalphEnabled = True
    , delegationMaxRounds    = 64
    }
  , modePTC         = PTCConfig False "" ""
  , modeHasPlan     = False
  , modeHasTodo     = False
  , modeHasWebSearch = False
  , modeHasShell    = True
  , modeMaxTokens   = 4096
  , modeContextSize = 65536
  }

-- | Get configuration for a mode
getModeConfig :: AgentMode -> ModeConfig
getModeConfig Standard = standardConfig
getModeConfig PTC      = ptcConfig
getModeConfig Minimal  = minimalConfig
getModeConfig Cordis   = cordisConfig

-- | All available modes with their configs
availableModes :: [(AgentMode, ModeConfig)]
availableModes = map (\m -> (m, getModeConfig m)) [minBound .. maxBound]

-- | Convert mode to text
modeToText :: AgentMode -> Text
modeToText Standard = "standard"
modeToText PTC      = "ptc"
modeToText Minimal  = "minimal"
modeToText Cordis   = "cordis"

-- | Parse text to mode
textToMode :: Text -> Maybe AgentMode
textToMode "standard" = Just Standard
textToMode "ptc"      = Just PTC
textToMode "minimal"  = Just Minimal
textToMode "cordis"   = Just Cordis
textToMode _          = Nothing

-- | Get tools for a mode
toolsForMode :: AgentMode -> [ToolDef]
toolsForMode = modeTools . getModeConfig

-- | Check if a mode has a specific tool
hasTool :: AgentMode -> Text -> Bool
hasTool mode tool = any (\t -> toolName t == tool && toolEnabled t) (toolsForMode mode)