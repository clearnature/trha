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
import Core.HTTP (createHTTPClient, httpGet)
import Core.Types (CLIConfig(..), CLIError, defaultCLIConfig)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Infrastructure.Sandbox
import Infrastructure.Sandbox.Audit (AuditEvent(..), readAudit)
import qualified Infrastructure.Sandbox.Backend.Linux as Linux
import Infrastructure.Sandbox.Config
import Infrastructure.Sandbox.Probe (runProbes)
import Infrastructure.Sandbox.Runner (RunnerConfig(..), runRunner)
import Options.Applicative
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, getCurrentDirectory, getHomeDirectory )
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (stderr, stdin, stdout)

data SandboxAction
  = SandboxStatus Bool       -- ^ True = JSON (machine-readable)
  | SandboxProbe (Maybe String)
  | SandboxPolicyGet (Maybe String)
  | SandboxPolicySet String FilePath
  | SandboxExec String [String]
  | SandboxAudit (Maybe String)
  | SandboxRunner FilePath FilePath Text (Maybe String) Text
  | SandboxConfigAction SandboxConfigPatch Bool
  | SandboxScopes
  deriving (Eq, Show)

data SandboxConfigPatch = SandboxConfigPatch
  { cfgEnabled :: Maybe Bool
  , cfgPolicy  :: Maybe String
  , cfgNetwork :: Maybe String
  , cfgScratch :: Maybe String
  } deriving (Eq, Show)

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
            <*> optional (strOption (long "scratch" <> metavar "DIR")))
      <*> switch (long "json" <> help "Machine-readable output")
    onOff "on" = Right True
    onOff "off" = Right False
    onOff other = Left ("expected on|off, got " ++ other)
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

runSandboxCommand :: SandboxAction -> IO ()
runSandboxCommand action = do
  home <- getHomeDirectory
  let path = home </> ".trha" </> "sandbox.yaml"
  exists <- doesFileExist path
  cfg <- if exists
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
            then emitJson "none" "none" False [T.pack (show err)]
            else do
              TIO.putStrLn "backend:     none"
              TIO.putStrLn ("reason:      " <> T.pack (show err))
        Right c -> do
          let backend = unBackendId (bcBackend c)
              enforcement = T.pack (show (bcEnforcement c))
              notes = bcNotes c
          if asJson
            then emitJson backend enforcement True notes
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
              TIO.putStrLn ("scopes:      " <> T.pack (show (map fst (scScopes cfg))))
    SandboxProbe _ -> do
      caps <- Linux.probeLinux
      case caps of
        Left err -> failWith (show err)
        Right c -> do
          ws <- getCurrentDirectory
          let scratch = home </> ".trha" </> "sandbox-scratch"
          createDirectoryIfMissing True scratch
          results <- runProbes Linux.backend c (mkRunnerScope ws scratch "workspace-write" "off")
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
      runRunnerMode ws scratch policyName experiment network
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
    SandboxConfigAction patch asJson -> do
      let noop = isNothing (cfgEnabled patch)
              && isNothing (cfgPolicy patch)
              && isNothing (cfgNetwork patch)
              && isNothing (cfgScratch patch)
          cfg' = if noop then cfg else applyConfigPatch cfg patch
      when (not noop) (saveSandboxConfig path cfg')
      if asJson then emitConfigJson cfg' else printConfig cfg'

printAudit :: AuditEvent -> IO ()
printAudit event = TIO.putStrLn $ T.intercalate "\t"
  [ aeTs event
  , T.pack (show (aeKind event))
  , aeScope event
  , aeTarget event
  , aeBackend event
  , aeEnforcement event
  ]

data ScopeRow = ScopeRow
  { srScopeId   :: Text
  , srParent    :: Maybe Text
  , srDepth     :: Int
  , srPolicy    :: Text
  , srIsolation :: Text
  } deriving (Eq, Show)

instance FromJSON ScopeRow where
  parseJSON = withObject "ScopeRow" $ \o -> ScopeRow
    <$> o .: "id"
    <*> o .:? "parent"
    <*> o .:? "depth" .!= 0
    <*> o .: "policy"
    <*> o .: "isolation"

newtype ScopesResponse = ScopesResponse [ScopeRow]

instance FromJSON ScopesResponse where
  parseJSON = withObject "ScopesResponse" $ \o -> ScopesResponse <$> o .: "scopes"

printScopeRow :: ScopeRow -> IO ()
printScopeRow row = TIO.putStrLn $
  T.replicate (max 0 (srDepth row)) "  "
    <> srScopeId row
    <> "  " <> srPolicy row
    <> " · " <> srIsolation row

applyConfigPatch :: SandboxConfig -> SandboxConfigPatch -> SandboxConfig
applyConfigPatch cfg' patch = cfg'
  { scEnabled = maybe (scEnabled cfg') id (cfgEnabled patch)
  , scDefaults = base
      { dcPolicy = maybe (dcPolicy base) T.pack (cfgPolicy patch)
      , dcNetwork = maybe (dcNetwork base) parseNetworkSpec (cfgNetwork patch)
      , dcScratch = maybe (dcScratch base) id (cfgScratch patch)
      }
  }
  where
    base = scDefaults cfg'

parseNetworkSpec :: String -> NetworkSpec
parseNetworkSpec raw = case T.stripPrefix "allow:" txt of
  Just domains -> NetAllow (filter (not . T.null) (map T.strip (T.splitOn "," domains)))
  Nothing -> case T.stripPrefix "proxy:" txt of
    Just url -> NetProxy url
    Nothing -> NetOff
  where
    txt = T.strip (T.pack raw)

networkSpecText :: NetworkSpec -> Text
networkSpecText NetOff = "off"
networkSpecText (NetAllow domains) = "allow:" <> T.intercalate "," domains
networkSpecText (NetProxy url) = "proxy:" <> url

emitConfigJson :: SandboxConfig -> IO ()
emitConfigJson cfg' = do
  let d = scDefaults cfg'
  BL.putStr (Aeson.encode (object
    [ "enabled" .= scEnabled cfg'
    , "policy" .= dcPolicy d
    , "network" .= networkSpecText (dcNetwork d)
    , "scratch" .= dcScratch d
    ]))
  TIO.putStrLn ""

printConfig :: SandboxConfig -> IO ()
printConfig cfg' = do
  let d = scDefaults cfg'
  TIO.putStrLn ("enabled:  " <> (if scEnabled cfg' then "on" else "off"))
  TIO.putStrLn ("policy:   " <> dcPolicy d)
  TIO.putStrLn ("network:  " <> networkSpecText (dcNetwork d))
  TIO.putStrLn ("scratch:  " <> T.pack (dcScratch d))

printProbe :: ProbeResult -> IO ()
printProbe result = TIO.putStrLn $ T.intercalate "\t"
  [ probeName result
  , if probeOk result then "ok" else "FAIL"
  , probeActual result
  ]

-- | Machine-readable status consumed by the scheduler/Desktop.
emitJson :: Text -> Text -> Bool -> [Text] -> IO ()
emitJson backend enforcement available notes = do
  BL.putStr (Aeson.encode (object
    [ "backend" .= backend
    , "platform" .= ("linux" :: Text)
    , "enforcement" .= enforcement
    , "available" .= available
    , "capabilities" .= ([] :: [Text])
    , "notes" .= notes
    ]))
  TIO.putStrLn ""

-- | Internal entry point used by the scheduler: read NDJSON from stdin,
-- execute through the Linux backend, write frames to stdout.
runRunnerMode :: FilePath -> FilePath -> T.Text -> Maybe String -> T.Text -> IO ()
runRunnerMode ws scratch policyName experiment network = do
  caps <- Linux.probeLinux
  case caps of
    Left err -> failWith (show err)
    Right c -> runRunner
      (RunnerConfig stdin stdout (T.pack <$> experiment))
      Linux.backend
      c
      (mkRunnerScope ws scratch policyName network)

mkRunnerScope :: FilePath -> FilePath -> T.Text -> T.Text -> Scope
mkRunnerScope ws scratch policyName networkSpec =
  scopeRoot (ScopeId "runner") policy (ExclusivePath (AbsolutePath scratch))
  where
    net = networkPolicyOf (parseNetworkSpec (T.unpack networkSpec))
    policy = case T.toLower policyName of
      "read-only" -> ReadOnly emptyReadOnlyPolicy
        { roReadableRoots = [AbsolutePath ws]
        , roNetwork = net
        }
      _ -> WorkspaceWrite WritableRoot
        { wrRoot = AbsolutePath ws
        , wrScratch = ExclusivePath (AbsolutePath scratch)
        , wrReadOnly = []
        , wrNetwork = net
        , wrLimits = defaultResourceLimits
        }

failWith :: String -> IO a
failWith message = do
  TIO.hPutStrLn stderr ("trha sandbox: " <> T.pack message)
  exitFailure
