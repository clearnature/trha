{-# LANGUAGE OverloadedStrings #-}

-- | 沙箱命令的输出层：审计/作用域/配置/探针的文本与 JSON 渲染。
--
-- 从 "Core.Sandbox" 拆出。这些函数只做「把已有数据打印成某种格式」，
-- 与解析（sandboxActionParser）和执行（runSandboxCommand）无关。
module Core.Sandbox.Report
  ( printAudit, ScopeRow(..), ScopesResponse(..), printScopeRow
  , emitConfigJson, printConfig, printProbe, emitJson, platformText
  , parseNetworkSpec, networkSpecText
  ) where

import Data.Aeson (FromJSON(..), object, withObject, (.:), (.:?), (.!=), (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Control.Monad (when)
import Config.Settings (resolveConfig)
import Core.HTTP (createHTTPClient, httpGet, httpPost)
import Core.Types (CLIConfig(..), CLIError, defaultCLIConfig)
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

emitConfigJson :: SandboxConfig -> IO ()
emitConfigJson cfg' = do
  let d = scDefaults cfg'
  BL.putStr (Aeson.encode (object
    [ "enabled" .= scEnabled cfg'
    , "policy" .= dcPolicy d
    , "network" .= networkSpecText (dcNetwork d)
    , "scratch" .= dcScratch d
    , "limits" .= object
        [ "pids" .= rlPids (dcLimits d)
        , "memoryMiB" .= rlMemoryMiB (dcLimits d)
        , "wallMs" .= rlWallMs (dcLimits d)
        ]
      -- §5.7.5 read.deny: null = shipped defaults, list = explicit override.
    , "denyReadDirs" .= dcDenyReadDirs d
    , "denyReadFiles" .= dcDenyReadFiles d
    ]))
  TIO.putStrLn ""

printConfig :: SandboxConfig -> IO ()
printConfig cfg' = do
  let d = scDefaults cfg'
  TIO.putStrLn ("enabled:  " <> (if scEnabled cfg' then "on" else "off"))
  TIO.putStrLn ("policy:   " <> dcPolicy d)
  TIO.putStrLn ("network:  " <> networkSpecText (dcNetwork d))
  TIO.putStrLn ("scratch:  " <> T.pack (dcScratch d))
  TIO.putStrLn ("limits:   pids=" <> T.pack (show (rlPids (dcLimits d)))
    <> " memoryMiB=" <> T.pack (show (rlMemoryMiB (dcLimits d)))
    <> " wallMs=" <> T.pack (show (rlWallMs (dcLimits d))))
  TIO.putStrLn ("deny:     dirs=" <> denyText (dcDenyReadDirs d)
    <> " files=" <> denyText (dcDenyReadFiles d))
  where
    denyText Nothing = "<defaults>"
    denyText (Just xs) = T.intercalate "," xs

printProbe :: ProbeResult -> IO ()
printProbe result = TIO.putStrLn $ T.intercalate "\t"
  [ probeName result
  , if probeOk result then "ok" else "FAIL"
  , probeActual result
  ]

-- | Machine-readable status consumed by the scheduler/Desktop (§5.7.4).
-- Capabilities and platform come from the probe, not from constants: the
-- Desktop renders them, and an empty list made every backend look the same.

emitJson :: Maybe BackendCapabilities -> [Text] -> IO ()
emitJson mcaps notes = do
  BL.putStr (Aeson.encode (object
    [ "backend" .= maybe "none" (unBackendId . bcBackend) mcaps
    , "platform" .= maybe (platformText (Other (T.pack os))) (platformText . bcPlatform) mcaps
    , "enforcement" .= maybe "none" (T.pack . show . bcEnforcement) mcaps
    , "available" .= maybe False (const True) mcaps
    , "capabilities" .= maybe [] (map (T.pack . show) . Set.toList . bcCapabilities) mcaps
    , "notes" .= notes
    ]))
  TIO.putStrLn ""

platformText :: Platform -> Text
platformText Linux = "linux"
platformText FreeBSD = "freebsd"
platformText OpenBSD = "openbsd"
platformText Darwin = "darwin"
platformText Windows = "win32"
platformText Android = "android"
platformText (Other name) = name

-- | Internal entry point used by the scheduler: read NDJSON from stdin,
-- execute through the Linux backend, write frames to stdout.
--
-- The config is the single source of truth for limits, readonly roots and the
-- env allow-list (T1.2/T2.3).  @--policy@ / @--network@ stay CLI overrides
-- because the scheduler passes them per scope.

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
