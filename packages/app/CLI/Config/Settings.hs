{-# LANGUAGE OverloadedStrings #-}

-- | Configuration loading for the trha CLI.
--
-- Layered, hardened settings management modelled on haskell-agent's
-- @~/.haskell-agent@ initialisation:
--
--   * settings live in @~/.trha/settings.yaml@ (user) and, optionally,
--     @<project>/.trha/settings.yaml@ (per-project override);
--   * effective value = defaults ⊂ user settings ⊂ project settings,
--     with @--host/--port/--model@ applied last by the caller;
--   * @~/.trha@ is created as a private directory (0700) and
--     @settings.yaml@ is written atomically with 0600 permissions
--     (temp file + rename), so a crash never corrupts the file;
--   * an unreadable settings file prints a warning and falls back to
--     defaults instead of aborting.
module Config.Settings
  ( -- * Entry point
    initConfig
  , saveConfig
    -- * Layered resolution (read-only; used by /settings)
  , resolveConfig
    -- * Paths
  , getConfigDir
  , getHomeConfigPath
  , getProjectConfigPath
    -- * Backups
  , backupSettings
  , backupKeep
  ) where

import Core.Types (CLIConfig(..), defaultCLIConfig)
import Control.Exception (try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (Result(..), Value(..), fromJSON, toJSON)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.List (isPrefixOf, isSuffixOf, sort)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Yaml (ParseException, decodeFileEither, encode)
import System.Directory
    ( copyFile
    , createDirectoryIfMissing
    , doesFileExist
    , getCurrentDirectory
    , getHomeDirectory
    , listDirectory
    , removeFile
    , renameFile
    )
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- | Initialise the user data directory and return the effective configuration.
--
-- * Creates @~/.trha@ (0700) and writes the default
--   @~/.trha/settings.yaml@ if it does not exist yet.
-- * Does /not/ create the directory skeleton: that is a one-time
--   installation step, done by @trha setup@ ('Config.Home.initHomeDirs').
--   Commands create the directories they write to on demand.
-- * Merges: defaults < @~/.trha/settings.yaml@ < @./.trha/settings.yaml@
--   (a per-project file is honoured when present, never auto-created).
initConfig :: IO CLIConfig
initConfig = do
  dir <- getConfigDir
  ensurePrivateDir dir
  homePath <- getHomeConfigPath
  exists <- doesFileExist homePath
  unless exists (writeSettingsAtomic homePath defaultCLIConfig)
  -- The file may pre-date the hardened initialiser; tighten it regardless.
  -- Read-only homes (a sandbox guest whose HOME is the scratch dir) cannot
  -- chmod: fsync-mode changes fail there, so tolerate the error instead of
  -- crashing every `trha` invocation inside the sandbox.
  _ <- try (setFileMode homePath 0o600) :: IO (Either IOError ())
  resolveConfig defaultCLIConfig

-- | Save configuration to @~/.trha/settings.yaml@ (atomic, 0600).
--
-- The previous file is copied to @~/.trha/backups/@ first: a bad wizard run
-- or a broken edit then has a rollback point instead of destroying the only
-- copy of the user's configuration.
saveConfig :: CLIConfig -> IO ()
saveConfig config = do
  dir <- getConfigDir
  ensurePrivateDir dir
  path <- getHomeConfigPath
  backupSettings dir path
  writeSettingsAtomic path config

-- | How many @settings-*.yaml@ rollback copies to keep.
backupKeep :: Int
backupKeep = 10

-- | Copy @path@ into @dir\/backups\/settings-<stamp>.yaml@ (no-op when the
-- file does not exist yet) and prune the oldest copies beyond 'backupKeep'.
backupSettings :: FilePath -> FilePath -> IO ()
backupSettings dir path = do
  exists <- doesFileExist path
  when exists $ do
    let bdir = dir </> "backups"
    createDirectoryIfMissing True bdir
    setFileMode bdir 0o700
    stamp <- formatTime defaultTimeLocale "%Y%m%d-%H%M%S" <$> getCurrentTime
    copyFile path (bdir </> ("settings-" <> stamp <> ".yaml"))
    pruneBackups bdir

-- | Drop the oldest @settings-*.yaml@ copies once there are more than
-- 'backupKeep'.  The stamp prefix sorts chronologically.
pruneBackups :: FilePath -> IO ()
pruneBackups bdir = do
  names <- sort <$> listDirectory bdir
  let ours = [ n | n <- names, "settings-" `isPrefixOf` n, ".yaml" `isSuffixOf` n ]
  forM_ (take (max 0 (length ours - backupKeep)) ours) $ \n ->
    removeFile (bdir </> n)

-- | @~/.trha@ (user data directory)
getConfigDir :: IO FilePath
getConfigDir = do
  home <- getHomeDirectory
  return $ home </> ".trha"

-- | @~/.trha/settings.yaml@
getHomeConfigPath :: IO FilePath
getHomeConfigPath = (</> "settings.yaml") <$> getConfigDir

-- | @./.trha/settings.yaml@ (per-project override, optional)
getProjectConfigPath :: IO FilePath
getProjectConfigPath = do
  cwd <- getCurrentDirectory
  return $ cwd </> ".trha" </> "settings.yaml"

--------------------------------------------------------------------------------
-- Layered resolution
--------------------------------------------------------------------------------

-- | Merge two YAML values; the second argument is the higher-precedence
-- layer and wins on key conflicts (project layer over user layer over
-- defaults).  Nested objects merge recursively.
mergeValues :: Value -> Value -> Value
mergeValues (Object lo) (Object hi) = Object (KM.unionWith mergeValues lo hi)
mergeValues _ hi = hi

-- | Read one settings file as a raw YAML value ('Nothing' when absent or
-- unreadable; a warning is printed for unreadable files).
readSettings :: FilePath -> IO (Maybe Value)
readSettings path = do
  exists <- doesFileExist path
  if not exists
    then return Nothing
    else do
      result <- decodeFileEither path :: IO (Either ParseException Value)
      case result of
        Right v  -> return (Just v)
        Left err -> do
          putStrLn $ "Warning: could not parse " ++ path ++ ": " ++ show err
          return Nothing

-- | Merge defaults < home settings < project settings and decode.
resolveConfig :: CLIConfig -> IO CLIConfig
resolveConfig fallback = do
  defV   <- pure (toJSON fallback)
  homeV  <- readSettings =<< getHomeConfigPath
  projV  <- readSettings =<< getProjectConfigPath
  let merged  = maybe defV (mergeValues defV) homeV
      merged2 = maybe merged (mergeValues merged) projV
  case fromJSON merged2 :: Result CLIConfig of
    Success cfg -> return (keepNonBlank fallback cfg)
    Error err   -> do
      putStrLn $ "Warning: invalid settings (using defaults): " ++ err
      return fallback

-- | A blank text field means "unset", not "empty".
--
-- Older builds wrote @configModel: ''@ into @~/.trha/settings.yaml@. The file
-- already exists, so it is never rewritten, and the empty value outlived the
-- bug: the footer showed @模型：@ with nothing after it and requests carried
-- @model: ""@. Blank fields now fall back to the built-in default.
keepNonBlank :: CLIConfig -> CLIConfig -> CLIConfig
keepNonBlank base cfg = cfg
  { configHost  = keep (configHost cfg)  (configHost base)
  , configScheme = keep (configScheme cfg) (configScheme base)
  , configModel = keep (configModel cfg) (configModel base)
  , configProvider = keep (configProvider cfg) (configProvider base)
  , configToken = keep (configToken cfg) (configToken base)
  , configTheme = keep (configTheme cfg) (configTheme base)
  , configLang  = keep (configLang cfg)  (configLang base)
  }
  where
    keep value fallbackValue
      | T.null (T.strip value) = fallbackValue
      | otherwise = value

--------------------------------------------------------------------------------
-- Private helpers
--------------------------------------------------------------------------------

-- | Create a directory that is only accessible by the owner (0700).
ensurePrivateDir :: FilePath -> IO ()
ensurePrivateDir dir = do
  createDirectoryIfMissing True dir
  setFileMode dir 0o700

-- | Write settings atomically with 0600 permissions: write to a temp file,
-- set permissions, then rename over the target so a crash never leaves a
-- half-written settings file behind.
writeSettingsAtomic :: FilePath -> CLIConfig -> IO ()
writeSettingsAtomic path config = do
  let tmp = path ++ ".tmp"
  BS.writeFile tmp (encode config)
  setFileMode tmp 0o600
  renameFile tmp path
