{-# LANGUAGE OverloadedStrings #-}

-- | @~/.trha/sandbox.yaml@ schema v1 (docs/plans/sandbox-architecture.md §5.7.5).
--
-- Parsing is strict on the top level: unknown keys and a version other than 1
-- are rejected instead of being ignored.
module Infrastructure.Sandbox.Config
  ( SandboxConfig(..)
  , DefaultsConfig(..)
  , ScopeConfig(..)
  , NetworkSpec(..)
  , defaultSandboxConfig
  , parseSandboxConfig
  , loadSandboxConfig
  , saveSandboxConfig
  , networkPolicyOf
  ) where

import Control.Monad (unless)
import Data.Aeson (ToJSON(..), Value(..), object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Yaml as Yaml
import Infrastructure.Sandbox.Policy
  ( NetworkPolicy(..), ResourceLimits(..), defaultResourceLimits )

data NetworkSpec
  = NetOff
  | NetAllow [Text]
  | NetProxy Text
  deriving (Eq, Show)

networkPolicyOf :: NetworkSpec -> NetworkPolicy
networkPolicyOf NetOff = NetworkOff
networkPolicyOf (NetAllow domains) = NetworkAllow domains
networkPolicyOf (NetProxy url) = NetworkProxy url

data DefaultsConfig = DefaultsConfig
  { dcPolicy        :: Text
  , dcIsolation     :: Text
  , dcNetwork       :: NetworkSpec
  , dcLimits        :: ResourceLimits
  , dcReadonlyRoots :: [FilePath]
  , dcEnvAllow      :: [Text]
  , dcScratch       :: FilePath
  } deriving (Eq, Show)

data ScopeConfig = ScopeConfig
  { scScopePolicy    :: Text
  , scScopeIsolation :: Text
  } deriving (Eq, Show)

data SandboxConfig = SandboxConfig
  { scVersion  :: Int
  , scEnabled  :: Bool
  , scDefaults :: DefaultsConfig
  , scScopes   :: [(Text, ScopeConfig)]
  } deriving (Eq, Show)

defaultSandboxConfig :: SandboxConfig
defaultSandboxConfig = SandboxConfig
  { scVersion = 1
  , scEnabled = False
  , scDefaults = DefaultsConfig
      { dcPolicy = "workspace-write"
      , dcIsolation = "process"
      , dcNetwork = NetOff
      , dcLimits = defaultResourceLimits
      , dcReadonlyRoots = ["~/.cabal", "~/.ghcup", "/usr", "/nix/store"]
      , dcEnvAllow = ["PATH", "HOME", "LANG", "TERM"]
      , dcScratch = "~/.trha/sandbox-scratch"
      }
  , scScopes = [("subagent", ScopeConfig "read-only" "process")]
  }

-- Writing ---------------------------------------------------------------

saveSandboxConfig :: FilePath -> SandboxConfig -> IO ()
saveSandboxConfig path cfg = Yaml.encodeFile path cfg

instance ToJSON SandboxConfig where
  toJSON c = object
    [ "version" .= scVersion c
    , "enabled" .= scEnabled c
    , "defaults" .= defaultsJson (scDefaults c)
    , "scopes" .= object
        [ Key.fromText k .= object
            [ "policy" .= scScopePolicy v
            , "isolation" .= scScopeIsolation v
            ]
        | (k, v) <- scScopes c ]
    ]

defaultsJson :: DefaultsConfig -> Value
defaultsJson d = object
  [ "policy" .= dcPolicy d
  , "isolation" .= dcIsolation d
  , "network" .= networkSpecText (dcNetwork d)
  , "scratch" .= dcScratch d
  , "limits" .= object
      [ "pids" .= rlPids (dcLimits d)
      , "memoryMiB" .= rlMemoryMiB (dcLimits d)
      , "wallMs" .= rlWallMs (dcLimits d)
      ]
  , "readonlyRoots" .= dcReadonlyRoots d
  , "envAllow" .= dcEnvAllow d
  ]

networkSpecText :: NetworkSpec -> Text
networkSpecText NetOff = "off"
networkSpecText (NetAllow domains) = "allow:" <> T.intercalate "," domains
networkSpecText (NetProxy url) = "proxy:" <> url

-- Parsing ---------------------------------------------------------------

parseSandboxConfig :: Value -> Either Text SandboxConfig
parseSandboxConfig value = case value of
  Object o -> do
    let allowed = ["version", "enabled", "defaults", "backends", "scopes", "experiments"]
        unknown = [Key.toString k | k <- KM.keys o, Key.toString k `notElem` allowed]
    unless (null unknown) $
      Left ("unknown top-level keys: " <> T.pack (show unknown))
    version <- case KM.lookup "version" o of
      Just (Number n) | n == 1 -> Right 1
      Just other -> Left ("unsupported version: " <> T.pack (show other))
      Nothing -> Right 1
    enabled <- case KM.lookup "enabled" o of
      Just (Bool b) -> Right b
      Just other -> Left ("enabled must be a boolean: " <> T.pack (show other))
      Nothing -> Right (scEnabled defaultSandboxConfig)
    defaults <- case KM.lookup "defaults" o of
      Nothing -> Right (scDefaults defaultSandboxConfig)
      Just v -> parseDefaults v
    scopes <- case KM.lookup "scopes" o of
      Nothing -> Right (scScopes defaultSandboxConfig)
      Just v -> parseScopes v
    pure SandboxConfig
      { scVersion = version
      , scEnabled = enabled
      , scDefaults = defaults
      , scScopes = scopes
      }
  _ -> Left "sandbox config must be a YAML object"

parseDefaults :: Value -> Either Text DefaultsConfig
parseDefaults (Object o) = do
  let base = scDefaults defaultSandboxConfig
  policy <- optionalText o "policy" (dcPolicy base)
  isolation <- optionalText o "isolation" (dcIsolation base)
  network <- parseNetwork =<< optionalValue o "network"
  limits <- case KM.lookup "limits" o of
    Nothing -> Right (dcLimits base)
    Just v -> parseLimits v
  roots <- optionalStringList o "readonlyRoots" (dcReadonlyRoots base)
  envAllow <- optionalTextList o "envAllow" (dcEnvAllow base)
  scratch <- optionalText o "scratch" (T.pack (dcScratch base))
  pure DefaultsConfig
    { dcPolicy = policy
    , dcIsolation = isolation
    , dcNetwork = network
    , dcLimits = limits
    , dcReadonlyRoots = roots
    , dcEnvAllow = envAllow
    , dcScratch = T.unpack scratch
    }
parseDefaults _ = Left "defaults must be an object"

parseLimits :: Value -> Either Text ResourceLimits
parseLimits (Object o) = do
  pids <- optionalInt o "pids" (rlPids defaultResourceLimits)
  mem <- optionalInt o "memoryMiB" (rlMemoryMiB defaultResourceLimits)
  wall <- optionalInt o "wallMs" (rlWallMs defaultResourceLimits)
  pure ResourceLimits { rlPids = pids, rlMemoryMiB = mem, rlWallMs = wall }
parseLimits _ = Left "limits must be an object"

parseNetwork :: Maybe Value -> Either Text NetworkSpec
parseNetwork Nothing = Right NetOff
parseNetwork (Just (String s)) = Right $ case T.strip s of
  "off" -> NetOff
  other
    | Just domains <- T.stripPrefix "allow:" other ->
        NetAllow (filter (not . T.null) (map T.strip (T.splitOn "," domains)))
    | Just url <- T.stripPrefix "proxy:" other -> NetProxy (T.strip url)
    | otherwise -> NetOff
parseNetwork (Just _) = Left "network must be a string"

parseScopes :: Value -> Either Text [(Text, ScopeConfig)]
parseScopes (Object o) = mapM parseOne (KM.toList o)
  where
    parseOne (k, Object s) = do
      policy <- optionalText s "policy" "read-only"
      isolation <- optionalText s "isolation" "process"
      pure (Key.toText k, ScopeConfig policy isolation)
    parseOne (k, _) = Left ("scope must be an object: " <> Key.toText k)
parseScopes _ = Left "scopes must be an object"

-- Helpers ---------------------------------------------------------------

optionalValue :: KM.KeyMap Value -> Text -> Either Text (Maybe Value)
optionalValue o key = pure (KM.lookup (Key.fromText key) o)

optionalText :: KM.KeyMap Value -> Text -> Text -> Either Text Text
optionalText o key fallback = case KM.lookup (Key.fromText key) o of
  Nothing -> Right fallback
  Just (String s) -> Right s
  Just _ -> Left (key <> " must be a string")

optionalInt :: KM.KeyMap Value -> Text -> Int -> Either Text Int
optionalInt o key fallback = case KM.lookup (Key.fromText key) o of
  Nothing -> Right fallback
  Just (Number n) -> Right (floor n)
  Just _ -> Left (key <> " must be a number")

optionalStringList :: KM.KeyMap Value -> Text -> [FilePath] -> Either Text [FilePath]
optionalStringList o key fallback = case KM.lookup (Key.fromText key) o of
  Nothing -> Right fallback
  Just (Array items) -> mapM parseOne (foldr (:) [] items)
  Just _ -> Left (key <> " must be an array of strings")
  where
    parseOne (String s) = Right (T.unpack s)
    parseOne _ = Left (key <> " must contain only strings")

optionalTextList :: KM.KeyMap Value -> Text -> [Text] -> Either Text [Text]
optionalTextList o key fallback = case KM.lookup (Key.fromText key) o of
  Nothing -> Right fallback
  Just (Array items) -> mapM parseOne (foldr (:) [] items)
  Just _ -> Left (key <> " must be an array of strings")
  where
    parseOne (String s) = Right s
    parseOne _ = Left (key <> " must contain only strings")

-- | Load and validate a config file. Missing files are an error; callers that
-- want defaults call 'defaultSandboxConfig' explicitly.
loadSandboxConfig :: FilePath -> IO (Either Text SandboxConfig)
loadSandboxConfig path = do
  parsed <- Yaml.decodeFileEither path
  pure $ case parsed of
    Left err -> Left (T.pack (Yaml.prettyPrintParseException err))
    Right value -> parseSandboxConfig value
