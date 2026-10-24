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
import Options.Applicative

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
  | CmdSettingsSchema
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
        <> help "Server port (default: 3456)"
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

-- | CLI subcommand
cliParser :: Parser SubCommand
cliParser = pure CmdCLI

-- | Serve subcommand.
--
-- The kernel port is deliberately separate from @configPort@: the latter is
-- how the CLI/TUI reaches the *scheduler* (3456), while this is where the
-- kernel's OpenAI-compatible API listens. 3333 keeps the two from colliding.
serveParser :: Parser SubCommand
serveParser = CmdServe
  <$> option auto
        ( long "kernel-port"
        <> metavar "PORT"
        <> value 3333
        <> showDefault
        <> help "Kernel API port (default: 3333; the scheduler talks to this)"
        )
  <*> optional (strOption
        ( long "state-dir"
        <> metavar "DIR"
        <> help "Persist kernel sessions to DIR (default: in-memory only)"
        ))

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
        <> command "settings-schema"
            (info (pure CmdSettingsSchema)
              (progDesc "Print the machine-readable settings schema (JSON)"))
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
