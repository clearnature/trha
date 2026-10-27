-- | The argv -> command mapping.
--
-- The behaviour that matters for an installed harness is the *default*: plain
-- @trha@ must start the TUI. That is decided by the parser (the subcommand is
-- optional) plus 'resolveCommand' (absent means 'CmdTUI'), so it is testable
-- without spawning a process or owning a terminal.
module Core.ArgsSpec (spec) where

import Data.Text ()
import qualified Data.Text as T
import Options.Applicative (ParserResult(..), defaultPrefs, execParserPure)
import Test.Hspec

import Core.Args

-- | Parse as @getArgs@ would hand the list over (no program name; optparse
-- derives that itself).
parseArgs :: [String] -> ParserResult (GlobalOpts, Maybe SubCommand)
parseArgs = execParserPure defaultPrefs cliParserInfo

-- | The subcommand the shell would dispatch on, or 'Nothing' if parsing failed.
commandOf :: [String] -> Maybe SubCommand
commandOf argv = case parseArgs argv of
  Success (_, mcmd) -> Just (resolveCommand mcmd)
  _                 -> Nothing

-- | The subcommand as parsed, keeping the distinction between "absent" and
-- "parse failed".
explicitOf :: [String] -> Maybe (Maybe SubCommand)
explicitOf argv = case parseArgs argv of
  Success (_, mcmd) -> Just mcmd
  _                 -> Nothing

spec :: Spec
spec = describe "command line" $ do
  it "treats no arguments as the TUI" $ do
    explicitOf [] `shouldBe` Just Nothing
    commandOf [] `shouldBe` Just CmdTUI

  it "still accepts an explicit tui subcommand" $
    commandOf ["tui"] `shouldBe` Just CmdTUI

  it "selects the REPL for `cli`" $
    commandOf ["cli"] `shouldBe` Just CmdCLI

  it "selects setup for `setup`" $ do
    commandOf ["setup"] `shouldBe` Just (CmdSetup False)
    commandOf ["setup", "--yes"] `shouldBe` Just (CmdSetup True)

  it "selects serve, defaulting the kernel port to 19433" $
    explicitOf ["serve"] `shouldBe` Just (Just (CmdServe 19433 Nothing))

  it "takes the kernel port and state dir when given" $
    explicitOf ["serve", "--kernel-port", "4000", "--state-dir", "/tmp/s"]
      `shouldBe` Just (Just (CmdServe 4000 (Just "/tmp/s")))

  it "parses stop with an optional service and --force" $ do
    explicitOf ["stop"] `shouldBe` Just (Just (CmdStop Nothing False))
    explicitOf ["stop", "kernel"] `shouldBe` Just (Just (CmdStop (Just "kernel") False))
    explicitOf ["stop", "scheduler", "--force"]
      `shouldBe` Just (Just (CmdStop (Just "scheduler") True))

  it "parses status" $
    explicitOf ["status"] `shouldBe` Just (Just CmdStatus)

  it "lets global options precede the default TUI" $ do
    case parseArgs ["--host", "10.0.0.2", "-p", "9999"] of
      Success (opts, mcmd) -> do
        optHost opts `shouldBe` Just (T.pack "10.0.0.2")
        optPort opts `shouldBe` Just 9999
        resolveCommand mcmd `shouldBe` CmdTUI
      other -> expectationFailure ("parse failed: " <> show other)

  it "rejects an unknown subcommand instead of silently starting the TUI" $
    commandOf ["nope"] `shouldBe` Nothing

  it "keeps -h for help (it is not a --host short option)" $
    case parseArgs ["-h"] of
      Failure _ -> pure ()
      other     -> expectationFailure ("-h was parsed as " <> show other)
