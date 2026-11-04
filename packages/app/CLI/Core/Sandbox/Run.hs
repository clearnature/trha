{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | 沙箱命令的执行层：把解析出的 'SandboxAction' 落到实际行为上
-- （状态查询、探针、配置读写、运行器启动）。
--
-- 从 "Core.Sandbox" 拆出。Core.Sandbox 只剩 CLI 解析与数据类型。
module Core.Sandbox.Run
  ( runSandboxCommand
  , applyConfigPatch
  , runRunnerMode
  , mkRunnerScope
  , expandHome
  , failWith
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
import Core.Sandbox.Types (SandboxAction(..), ExperimentArgs(..), SandboxConfigPatch(..))
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

runSandboxCommand :: SandboxAction -> IO ()
runSandboxCommand action = do
  home <- getHomeDirectory
  let path = home </> ".trha" </> "sandbox.yaml"
  -- Inside the sandbox HOME *is* the scratch dir, so a file at this path is a
  -- guest-local copy (written by an earlier `sandbox config` in a guest), not
  -- the host's authoritative config.  Trusting it reported "disabled / pids 0"
  -- while execution actually used the host's enabled/512/2 GiB — a fail-open.
  -- Refuse to read it either way, whether or not a copy happens to exist.
  guest <- insideSandbox
  exists <- doesFileExist path
  cfg <-
    if guest
      then failWith ("running inside the sandbox: " <> path
             <> " is guest-local (HOME is the scratch dir), not the host config."
             <> " Run `trha sandbox status` on the host, or query"
             <> " /api/sandbox/status on the scheduler.")
      else
        if exists
          then do
            parsed <- loadSandboxConfig path
            either (failWith . T.unpack) pure parsed
          else pure defaultSandboxConfig
  case action of
    SandboxStatus asJson -> do
      caps <- Linux.probeLinux
      case caps of
        Left err -> do
          if asJson
            then emitJson Nothing [T.pack (show err)]
            else do
              TIO.putStrLn "backend:     none"
              TIO.putStrLn ("reason:      " <> T.pack (show err))
        Right c -> do
          let backend = unBackendId (bcBackend c)
              enforcement = T.pack (show (bcEnforcement c))
              notes = bcNotes c
          if asJson
            then emitJson (Just c) notes
            else do
              TIO.putStrLn ("backend:     " <> backend)
              TIO.putStrLn ("enforcement: " <> enforcement)
              TIO.putStrLn ("capabilities:" <> " " <> T.pack (show (bcCapabilities c)))
              mapM_ (\n -> TIO.putStrLn ("note:        " <> n)) notes
              TIO.putStrLn ("config:      " <> T.pack path
                <> (if exists then "" else " (defaults; file not found)"))
              let d = scDefaults cfg
              TIO.putStrLn ("policy:      " <> dcPolicy d)
              TIO.putStrLn ("isolation:   " <> dcIsolation d)
              TIO.putStrLn ("network:     " <> T.pack (show (dcNetwork d)))
              TIO.putStrLn ("limits:      pids=" <> T.pack (show (rlPids (dcLimits d)))
                <> " memoryMiB=" <> T.pack (show (rlMemoryMiB (dcLimits d)))
                <> " wallMs=" <> T.pack (show (rlWallMs (dcLimits d))))
              TIO.putStrLn ("readonly:    " <> T.pack (show (dcReadonlyRoots d)))
              when (rlMemoryMiB (dcLimits d) > 0) $
                TIO.putStrLn ("warn:        memoryMiB caps RLIMIT_AS; node/GHC builds abort — `trha sandbox config --memory-mib 0` to lift")
              TIO.putStrLn ("scopes:      " <> T.pack (show (map fst (scScopes cfg))))
    SandboxProbe _ -> do
      caps <- Linux.probeLinux
      case caps of
        Left err -> failWith (show err)
        Right c -> do
          ws <- getCurrentDirectory
          let scratch = home </> ".trha" </> "sandbox-scratch"
          createDirectoryIfMissing True scratch
          results <- runProbes Linux.backend c (mkRunnerScope cfg home ws scratch "workspace-write" "off")
          mapM_ printProbe results
          if all probeOk results then pure () else exitFailure
    SandboxPolicyGet mscope -> do
      let d = scDefaults cfg
      TIO.putStrLn ("scope:       " <> maybe "default" T.pack mscope)
      TIO.putStrLn ("policy:      " <> dcPolicy d)
      TIO.putStrLn ("source:      " <> T.pack path)
    SandboxPolicySet _ _ ->
      failWith "policy set is not implemented yet (P0 skeleton)"
    SandboxExec _ _ ->
      failWith "sandbox exec requires a backend; refusing to run unconfined"
    SandboxAudit _ -> do
      events <- readAudit 50
      if null events
        then TIO.putStrLn "no audit events"
        else mapM_ printAudit events
    SandboxRunner ws scratch policyName experiment network ->
      runRunnerMode cfg ws scratch policyName experiment network
    SandboxScopes -> do
      cliCfg <- resolveConfig defaultCLIConfig
      client <- createHTTPClient (configScheme cliCfg) (configHost cliCfg)
                  (configPort cliCfg) (configToken cliCfg) 8000 (configProxy cliCfg)
      r <- httpGet client "/api/sandbox/scopes" :: IO (Either CLIError ScopesResponse)
      case r of
        Left e -> failWith (show e)
        Right (ScopesResponse rows) ->
          if null rows
            then TIO.putStrLn "no scopes"
            else mapM_ printScopeRow rows
    SandboxExperiment args asJson -> do
      let payload = object
            [ "id" .= T.pack (eaId args)
            , "root" .= T.pack (eaRoot args)
            , "baseline" .= T.pack (eaBaseline args)
            , "variants" .= [ object ["id" .= T.pack v] | v <- eaVariants args ]
            , "seeds" .= eaSeeds args
            , "concurrency" .= eaConcurrency args
            , "retries" .= eaRetries args
            , "command" .= map T.pack (eaCommand args)
            ]
      cliCfg <- resolveConfig defaultCLIConfig
      client <- createHTTPClient (configScheme cliCfg) (configHost cliCfg)
                  (configPort cliCfg) (configToken cliCfg) 3600000 (configProxy cliCfg)
      r <- httpPost client "/api/sandbox/experiment" payload :: IO (Either CLIError Aeson.Value)
      case r of
        Left e -> failWith (show e)
        Right v -> do
          let pretty = BL.putStr (Aeson.encode v) >> TIO.putStrLn ""
          -- The outcome JSON is the deliverable: keep a copy where the user
          -- looks, in addition to what the scheduler wrote as repro.json.
          dest <- case eaOutput args of
            Just p -> pure p
            Nothing -> pure (home </> ".trha" </> "experiments" </> eaId args <.> "json")
          BL.writeFile dest (Aeson.encode v)
          if asJson
            then pretty
            else do
              TIO.putStrLn ("submitted:   " <> T.pack (eaId args))
              TIO.putStrLn ("outcome:     " <> T.pack dest)
              pretty
    SandboxConfigAction patch asJson -> do
      let noop = isNothing (cfgEnabled patch)
              && isNothing (cfgPolicy patch)
              && isNothing (cfgNetwork patch)
              && isNothing (cfgScratch patch)
              && isNothing (cfgPids patch)
              && isNothing (cfgMemory patch)
              && isNothing (cfgWall patch)
              && isNothing (cfgDenyDirs patch)
              && isNothing (cfgDenyFiles patch)
          cfg' = if noop then cfg else applyConfigPatch cfg patch
      when (not noop) (saveSandboxConfig path cfg')
      if asJson then emitConfigJson cfg' else printConfig cfg'





applyConfigPatch :: SandboxConfig -> SandboxConfigPatch -> SandboxConfig
applyConfigPatch cfg' patch = cfg'
  { scEnabled = maybe (scEnabled cfg') id (cfgEnabled patch)
  , scDefaults = base
      { dcPolicy = maybe (dcPolicy base) T.pack (cfgPolicy patch)
      , dcNetwork = maybe (dcNetwork base) parseNetworkSpec (cfgNetwork patch)
      , dcScratch = maybe (dcScratch base) id (cfgScratch patch)
      , dcLimits = limits
      , dcDenyReadDirs = maybe (dcDenyReadDirs base) (Just . map T.strip . filter (not . T.null)) (cfgDenyDirs patch)
      , dcDenyReadFiles = maybe (dcDenyReadFiles base) (Just . map T.strip . filter (not . T.null)) (cfgDenyFiles patch)
      }
  }
  where
    base = scDefaults cfg'
    limits = ResourceLimits
      { rlPids = maybe (rlPids (dcLimits base)) id (cfgPids patch)
      , rlMemoryMiB = maybe (rlMemoryMiB (dcLimits base)) id (cfgMemory patch)
      , rlWallMs = maybe (rlWallMs (dcLimits base)) id (cfgWall patch)
      }






runRunnerMode :: SandboxConfig -> FilePath -> FilePath -> T.Text -> Maybe String -> T.Text -> IO ()
runRunnerMode cfg ws scratch policyName experiment network = do
  home <- getHomeDirectory
  let scope = mkRunnerScope cfg home ws scratch policyName network
#ifdef mingw32_HOST_OS
  -- Windows: the Windows backend renders the AppContainer launch itself.
  -- bwrap does not exist on this host, so probing the Linux backend here
  -- would fail the runner before any frame.
  caps <- Windows.probeWindows
  case caps of
    Left err -> failWith (show err)
    Right c -> runRunner
      (RunnerConfig stdin stdout (T.pack <$> experiment))
      Windows.backend c scope
#else
  caps <- Linux.probeLinux
  case caps of
    Left err -> failWith (show err)
    Right c -> runRunner
      (RunnerConfig stdin stdout (T.pack <$> experiment))
      Linux.backend c scope
#endif

-- | Build the runner scope from the config defaults.
mkRunnerScope :: SandboxConfig -> FilePath -> FilePath -> FilePath -> T.Text -> T.Text -> Scope
mkRunnerScope cfg home ws scratch policyName networkSpec =
  scopeRoot (ScopeId "runner") policy (ExclusivePath (AbsolutePath (expandHome home scratch)))
  where
    d = scDefaults cfg
    net = networkPolicyOf (parseNetworkSpec (T.unpack networkSpec))
    ro = map (AbsolutePath . expandHome home) (dcReadonlyRoots d)
    homeDir = expandHome home scratch
    policy = case T.toLower policyName of
      "read-only" -> ReadOnly emptyReadOnlyPolicy
        { roReadableRoots = AbsolutePath ws : ro
        , roNetwork = net
        , roEnvAllow = dcEnvAllow d
        }
      _ -> WorkspaceWrite WritableRoot
        { wrRoot = AbsolutePath ws
        , wrScratch = ExclusivePath (AbsolutePath homeDir)
        , wrReadOnly = ro
        , wrNetwork = net
        , wrLimits = dcLimits d
          -- §5.7.5 read.deny: the config's list, if set, replaces the shipped
          -- defaults at the *policy* level — narrow() keeps a parent override,
          -- so subagent scopes inherit it too.
        , wrDenyReadDirs = dcDenyReadDirs d
        , wrDenyReadFiles = dcDenyReadFiles d
        }

-- | @~@ in the config expands against the (host) home of the runner.
expandHome :: FilePath -> FilePath -> FilePath
expandHome home path = case path of
  '~':'/':rest -> home </> rest
  "~" -> home
  _ -> path

failWith :: String -> IO a
failWith message = do
  TIO.hPutStrLn stderr ("trha sandbox: " <> T.pack message)
  exitFailure
