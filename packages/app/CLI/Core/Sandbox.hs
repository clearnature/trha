{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | @trha sandbox@ subcommands (P0 skeleton, docs/plans/sandbox-delivery-plan.md T0.9).
--
-- The status command reads @~/.trha/sandbox.yaml@ and reports the defaults.
-- Execution/probe/policy-set are intentionally refused until the runner
-- lands (T1.4/T1.6): a stub that pretends to work would hide the missing
-- boundary.
module Core.Sandbox
  ( SandboxAction(..)
  , sandboxActionParser
  , runSandboxCommand
  ) where

import Data.Aeson (FromJSON(..), object, withObject, (.:), (.:?), (.!=), (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Control.Monad (when)
import Config.Settings (resolveConfig)
import Core.HTTP (createHTTPClient, httpGet, httpPost)
import Core.Types (CLIConfig(..), CLIError, defaultCLIConfig)
import Core.Sandbox.Report
  ( ScopesResponse(..), emitConfigJson, emitJson, networkSpecText, parseNetworkSpec
  , platformText, printAudit, printConfig, printProbe, printScopeRow )
import Core.Sandbox.Types (ExperimentArgs(..), SandboxAction(..), SandboxConfigPatch(..))
import Core.Sandbox.Run
  ( applyConfigPatch, expandHome, failWith, mkRunnerScope
  , runRunnerMode, runSandboxCommand )
import Data.Maybe (fromMaybe, isNothing)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Infrastructure.Sandbox
import Infrastructure.Sandbox.Audit (AuditEvent(..), readAudit)
import qualified Infrastructure.Sandbox.Backend.Linux as Linux
import qualified Infrastructure.Sandbox.Backend.Windows as Windows
import Infrastructure.Sandbox.Config
import Infrastructure.Sandbox.Probe (runProbes)
import Infrastructure.Sandbox.Runner (RunnerConfig(..), runRunner)
import Options.Applicative
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, getCurrentDirectory, getHomeDirectory )
import System.Exit (exitFailure)
import System.FilePath ((</>), (<.>))
import System.Info (os)
import System.IO (stderr, stdin, stdout)

sandboxActionParser :: Parser SandboxAction
sandboxActionParser = subparser
  ( command "status"
      (info (SandboxStatus <$> switch (long "json" <> help "Machine-readable JSON") <**> helper)
        (progDesc "Show the sandbox backend, enforcement and effective defaults"))
 <> command "probe"
      (info (probeParser <**> helper)
        (progDesc "Run the backend probes for a scope"))
 <> command "policy"
      (info (policyParser <**> helper)
        (progDesc "Get or set the policy for a scope"))
 <> command "exec"
      (info (execParser <**> helper)
        (progDesc "Run a command inside a scope (requires a backend)"))
 <> command "audit"
      (info (auditParser <**> helper)
        (progDesc "Show recent sandbox audit events"))
 <> command "runner"
      (info (runnerParser <**> helper)
        (progDesc "NDJSON runner used by the scheduler (internal)"))
 <> command "config"
      (info (configParser <**> helper)
        (progDesc "Show or update ~/.trha/sandbox.yaml (enabled/policy/network/scratch)"))
 <> command "scopes"
      (info (pure SandboxScopes <**> helper)
        (progDesc "List execution scopes (the agent/session tree)"))
 <> command "experiment"
      (info (experimentParser <**> helper)
        (progDesc "Submit an experiment batch to the scheduler"))
  ) <**> helper
  where
    probeParser = SandboxProbe <$> optional (strOption
      ( long "scope" <> metavar "ID" <> help "Scope id (default: current session)"))
    policyParser = subparser
      ( command "get"
          (info (SandboxPolicyGet <$> optional (strOption
            ( long "scope" <> metavar "ID")))
            (progDesc "Print the effective policy"))
     <> command "set"
          (info (SandboxPolicySet
            <$> strOption (long "scope" <> metavar "ID")
            <*> strArgument (metavar "FILE"))
            (progDesc "Replace a scope policy from a YAML/JSON file"))
      )
    execParser = SandboxExec
      <$> strOption (long "scope" <> metavar "ID")
      <*> many (strArgument (metavar "ARGV..."))
    auditParser = SandboxAudit <$> optional (strOption
      ( long "since" <> metavar "TS" <> help "Only events after this timestamp"))
    configParser = SandboxConfigAction
      <$> (SandboxConfigPatch
            <$> optional (option (eitherReader onOff)
                  (long "enabled" <> metavar "on|off" <> help "Enable or disable the sandbox"))
            <*> optional (strOption (long "policy" <> metavar "POLICY"))
            <*> optional (strOption (long "network" <> metavar "SPEC" <> help "off | allow:host1,host2 | proxy:url"))
            <*> optional (strOption (long "scratch" <> metavar "DIR"))
            <*> optional (option auto (long "pids" <> metavar "N"
                  <> help "cgroup v2 pids.max for each exec (0 = no limit)"))
            <*> optional (option auto (long "memory-mib" <> metavar "MiB"
                  <> help "RLIMIT_AS in MiB (0 = no limit; keep 0 for builds)"))
            <*> optional (option auto (long "wall-ms" <> metavar "MS"
                  <> help "default wall timeout per exec"))
            <*> optional (option (eitherReader commaList) (long "deny-dirs" <> metavar "A,B"
                  <> help "home-relative dirs to mask inside the sandbox (empty = no override list)"))
            <*> optional (option (eitherReader commaList) (long "deny-files" <> metavar "A,B"
                  <> help "home-relative files masked with /dev/null")))
      <*> switch (long "json" <> help "Machine-readable output")
    onOff "on" = Right True
    onOff "off" = Right False
    onOff other = Left ("expected on|off, got " ++ other)
    -- "" is a valid explicit empty list; a plain split would yield [""], so
    -- drop blank entries.
    commaList raw = Right (filter (not . T.null) (map T.strip (T.splitOn "," (T.pack raw))))
    experimentParser = SandboxExperiment
      <$> (ExperimentArgs
            <$> strOption (long "id" <> metavar "ID")
            <*> strOption (long "root" <> metavar "DIR")
            <*> strOption (long "baseline" <> metavar "DIR")
            <*> many (strOption (long "variant" <> metavar "ID"))
            <*> many (option auto (long "seed" <> metavar "N"))
            <*> some (strArgument (metavar "ARGV..."))
            <*> option auto
                  (long "concurrency" <> metavar "N" <> value 1
                    <> help "parallel tasks 1..16")
            <*> option auto
                  (long "retries" <> metavar "N" <> value 0
                    <> help "fresh-dir retries per failed task 0..4")
            <*> optional (strOption (long "output" <> metavar "FILE"
                    <> help "copy the outcome JSON here (default ~/.trha/experiments/<id>.json)")))
      <*> switch (long "json" <> help "Machine-readable output only")
    runnerParser = SandboxRunner
      <$> strOption (long "workspace" <> metavar "DIR" <> help "Workspace root")
      <*> strOption (long "scratch" <> metavar "DIR" <> help "Exclusive scratch directory")
      <*> strOption (long "policy" <> metavar "POLICY"
            <> value "workspace-write"
            <> help "read-only | workspace-write")
      <*> optional (strOption (long "experiment" <> metavar "TAG"
            <> help "Experiment tag recorded in the audit log (batch:variant:seed)"))
      <*> strOption (long "network" <> metavar "SPEC" <> value "off"
            <> help "off | allow:host1,host2 | proxy:url")
