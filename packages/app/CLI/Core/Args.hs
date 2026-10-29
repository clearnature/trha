-- | Command-line surface of the @trha@ executable.
--
-- Kept out of @Main@ so the "no subcommand means TUI" rule can be tested: the
-- parser is a pure 'ParserInfo', and a spec can run it over an argv list
-- without spawning the binary.
module Core.Args
  ( GlobalOpts(..)
  , SubCommand(..)
  , resolveCommand
  , globalOptsParser
  , commandParser
  , cliParserInfo
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Core.Sandbox (SandboxAction(..), sandboxActionParser)
import Options.Applicative
import qualified Data.Text as T

-- | Global options (shared across subcommands)
data GlobalOpts = GlobalOpts
  { optHost  :: Maybe Text
  , optPort  :: Maybe Int
  , optModel :: Maybe Text
  , optTheme :: Maybe Text
  , optLang  :: Maybe Text
  } deriving (Show)

-- | Subcommand
data SubCommand
  = CmdTUI
  | CmdCLI
  | CmdServe Int (Maybe FilePath)
  | CmdSetup Bool          -- ^ True = --yes (non-interactive)
  | CmdSettingsSchema
  | CmdFonts Text
  | CmdStop (Maybe String) Bool  -- ^ service (Nothing = all), --force
  | CmdStatus
  | CmdSandbox SandboxAction
  deriving (Eq, Show)

-- | Global options parser
globalOptsParser :: Parser GlobalOpts
globalOptsParser = GlobalOpts
  <$> optional (strOption
        ( long "host"
        <> metavar "HOST"
        <> help "Server host (default: localhost)"
        ))
  <*> optional (option auto
        ( long "port"
        <> short 'p'
        <> metavar "PORT"
        <> help "Server port (default: 28433)"
        ))
  <*> optional (strOption
        ( long "model"
        <> short 'm'
        <> metavar "MODEL"
        <> help "Model name (default: deepseek-flash)"
        ))
  <*> optional (strOption
        ( long "theme"
        <> metavar "THEME"
        <> help "TUI theme: tokyo-night | light (default: tokyo-night)"
        ))
  <*> optional (strOption
        ( long "lang"
        <> metavar "LANG"
        <> help "Interface language: zh | en (default: zh)"
        ))

-- | TUI subcommand
tuiParser :: Parser SubCommand
tuiParser = pure CmdTUI

-- | @trha fonts [status|activate|tty]@
fontsParser :: Parser SubCommand
fontsParser = CmdFonts . T.pack <$> strArgument
  ( metavar "ACTION"
 <> value "status"
 <> help "status | activate | tty (default: status)" )

-- | @trha setup [--yes]@
setupParser :: Parser SubCommand
setupParser = CmdSetup <$> switch
  ( long "yes"
 <> short 'y'
 <> help "Non-interactive: create the directory skeleton, keep the current settings"
 )

-- | CLI subcommand
cliParser :: Parser SubCommand
cliParser = pure CmdCLI

-- | Serve subcommand.
--
-- The kernel port is deliberately separate from @configPort@: the latter is
-- how the CLI/TUI reaches the *scheduler* (28433), while this is where the
-- kernel's OpenAI-compatible API listens. 19433 keeps the two from colliding.
serveParser :: Parser SubCommand
serveParser = CmdServe
  <$> option auto
        ( long "kernel-port"
        <> metavar "PORT"
        <> value 19433
        <> showDefault
        <> help "Kernel API port (default: 19433; the scheduler talks to this)"
        )
  <*> optional (strOption
        ( long "state-dir"
        <> metavar "DIR"
        <> help "Persist kernel sessions to DIR (default: in-memory only)"
        ))

-- | Stop the services recorded in @~/.trha/run/*.pid@.
--
-- No service name (or @all@) stops both.  SIGTERM first; @--force@ is the
-- only way to escalate to SIGKILL, and only after the five-second timeout.
stopParser :: Parser SubCommand
stopParser = CmdStop
  <$> optional (strArgument
        ( metavar "SERVICE"
        <> help "kernel | scheduler (default: all)"
        ))
  <*> switch
        ( long "force"
        <> help "SIGKILL after the 5s timeout (default: report and leave it)"
        )

-- | Command parser with subcommands.
--
-- The subcommand is optional: running @trha@ with no arguments starts the TUI,
-- which is what an installed harness should do. @trha cli@ / @serve@ keep
-- working as before.
commandParser :: Parser (GlobalOpts, Maybe SubCommand)
commandParser = (,)
  <$> globalOptsParser
  <*> optional (subparser
        ( command "tui"
            (info tuiParser
              (progDesc "Run in TUI mode (fullscreen terminal UI, the default)"))
        <> command "cli"
            (info cliParser
              (progDesc "Run in CLI mode (interactive REPL)"))
        <> command "serve"
            (info serveParser
              (progDesc "Start API server"))
        <> command "setup"
            (info setupParser
              (progDesc "Interactive setup: directory skeleton, language, theme, provider"))
        <> command "fonts"
            (info fontsParser
              (progDesc "Bundled-font helpers: status / activate / tty"))
        <> command "settings-schema"
            (info (pure CmdSettingsSchema)
              (progDesc "Print the machine-readable settings schema (JSON)"))
        <> command "stop"
            (info stopParser
              (progDesc "Stop the kernel and scheduler (usage: trha stop [kernel|scheduler] [--force])"))
        <> command "status"
            (info (pure CmdStatus)
              (progDesc "Show the kernel/scheduler pids and whether they are alive (read-only)"))
        <> command "sandbox"
            (info (CmdSandbox <$> sandboxActionParser)
              (progDesc "Sandbox backend status, probes, scope policies and audit"))
        ))

-- | The full parser, help included.
cliParserInfo :: ParserInfo (GlobalOpts, Maybe SubCommand)
cliParserInfo = info (commandParser <**> helper)
  ( fullDesc
  <> progDesc "trha agent harness (no subcommand starts the TUI)"
  <> header "trha - A microkernel agent harness"
  )

-- | No subcommand means TUI.
resolveCommand :: Maybe SubCommand -> SubCommand
resolveCommand = fromMaybe CmdTUI
