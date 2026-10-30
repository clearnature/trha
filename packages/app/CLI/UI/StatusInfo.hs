{-# LANGUAGE OverloadedStrings #-}

-- | System / environment info for the /settings "Status" tab -- a direct
-- port of the reference CLI status panel (qwen-code / Claude Code):
-- a two-column list of key/value facts about the shell, runtime, auth,
-- endpoints, session and memory.
--
-- Pure parsing helpers are unit-testable; the IO collector is a thin
-- shell over them.
module UI.StatusInfo
  ( -- * Rows
    StatusRow(..)
  , collectStatusInfo
    -- * Pure helpers
  , versionLine
  , runtimeLine
  , osLine
  , memoryLine
  , baseUrlLine
  , parsePages
  , authLine
  ) where

import Control.Exception (IOException, try)
import Core.Types (CLIConfig(..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Text.Read (decimal)
import Data.Maybe (fromMaybe)
import System.Directory (getCurrentDirectory, getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Info (arch, compilerName, compilerVersion, os)
import Infrastructure.Sandbox.Config (insideSandbox, loadSandboxConfig, scEnabled)
import Data.Version (showVersion)

-- | One status row: English label key (localised at render time via
-- 'UI.I18n.tr') and the value text.
data StatusRow = StatusRow
  { srLabel :: Text
  , srValue :: Text
  } deriving (Show, Eq)

-- | Product label + version line (e.g. @trha 0.1.0@).
versionLine :: Text
versionLine = "trha 0.1.0"

-- | Runtime line, e.g. @GHC 9.14.1@.
runtimeLine :: Text
runtimeLine = T.pack (compilerName <> " " <> showVersion compilerVersion)

-- | Operating system line: @linux x64 (kernel 6.8.0-31-generic)@ style.
osLine :: IO Text
osLine = do
  kernel <- readFirstLine "/proc/sys/kernel/osrelease"
  return $ T.pack os <> " " <> T.pack arch
    <> maybe "" (\k -> " (" <> k <> ")") kernel
  where
    readFirstLine fp = do
      content <- tryRead fp
      return (fmap (T.strip . T.takeWhile (/= '\n')) content)

-- | Base URL of the orchestration scheduler: @http://host:port@.
baseUrlLine :: CLIConfig -> Text
baseUrlLine cfg =
  let host = configHost cfg
      -- Show the loopback address the scheduler actually binds to.
      shown = if T.toLower (T.strip host) == "localhost" then "127.0.0.1" else host
      scheme = if T.toLower (T.strip (configScheme cfg)) == "http" then "http" else "https"
  in scheme <> "://" <> shown <> ":" <> T.pack (show (configPort cfg)) <> "/"

-- | Memory usage of this process in megabytes (RSS), read from
-- @/proc/self/statm@ on Linux; 'Nothing' elsewhere.
memoryLine :: IO (Maybe Text)
memoryLine = do
  mstat <- tryRead "/proc/self/statm"
  case mstat of
    Nothing -> return Nothing
    Just raw ->
      let pages = parsePages raw
      in return $ fmap (\p -> T.pack (showRounded (fromIntegral p * pageSize / 1024 / 1024))) pages
  where
    pageSize = 4096 :: Double
    showRounded mb = show (fromIntegral (round (mb * 10)) / (10 :: Double))

-- | Parse the resident-set page count out of a @/proc/self/statm@ line
-- (fields: size resident shared text lib data dt -- page counts).
parsePages :: Text -> Maybe Int
parsePages raw =
  case T.words raw of
    (_ : rss : _) -> case decimal rss of
      Right (n, rest) | T.null (T.strip rest) -> Just n
      _ -> Nothing
    _ -> Nothing

-- | Collect every row for the status panel.
collectStatusInfo :: CLIConfig -> Maybe String -> Text -> IO [StatusRow]
collectStatusInfo cfg mSid model = do
  osStr <- osLine
  mem <- memoryLine
  sandbox <- sandboxLine
  return
    [ StatusRow "Name" versionLine
    , StatusRow "Runtime" runtimeLine
    , StatusRow "OS" osStr
    , StatusRow "Auth" (authLine cfg)
    , StatusRow "Base URL" (baseUrlLine cfg)
    , StatusRow "Model" model
    , StatusRow "Session ID" (maybe "—" T.pack mSid)
    , StatusRow "SandBox" (sandbox <> "   Agent模式：" <> configAgentPreset cfg)
    , StatusRow "Memory" (fromMaybe "—" mem)
    ]

-- | The effective sandbox switch: an explicit env value wins, otherwise the
-- persisted ~/.trha/sandbox.yaml 'enabled' flag (what the scheduler loads).
--
-- Inside the sandbox HOME points at the scratch dir, so the host config is not
-- visible there and a failed load says nothing about whether the seam is on.
-- A guest process by definition runs sandboxed, so report that instead of the
-- "disabled" that a missing file used to imply.
sandboxLine :: IO Text
sandboxLine = do
  envV <- lookupEnv "TRHA_SANDBOX"
  home <- getHomeDirectory
  loaded <- loadSandboxConfig (home </> ".trha" </> "sandbox.yaml")
  guest <- insideSandbox
  let cfgOn = either (const False) scEnabled loaded
      envOn = case fmap (T.toLower . T.strip . T.pack) envV of
        Just v | v `elem` ["on", "1", "true", "enforce"] -> Just True
        Just _ -> Just False
        Nothing -> Nothing
      on = case envOn of
        Just v -> v
        Nothing | guest -> True
        Nothing -> cfgOn
  pure (if on then "enabled (linux-bwrap)" else "disabled")

-- | The workspace the tools use: the explicit override, else the shell's
-- current directory (the scheduler follows the same rule).
workspaceLine :: IO Text
workspaceLine = do
  override <- lookupEnv "TRHA_WORKSPACE"
  case override of
    Just p | not (null p) -> pure (T.pack p)
    _                     -> T.pack <$> getCurrentDirectory

-- | Auth summary: mask the token, noting the well-known dev default.
authLine :: CLIConfig -> Text
authLine cfg
  | configToken cfg == "dev-token" = "dev-token (default)"
  | T.null (configToken cfg) = "none"
  | otherwise = maskToken (configToken cfg)

-- | Show only the first four characters of a token.
maskToken :: Text -> Text
maskToken v
  | T.length v <= 4 = "****"
  | otherwise = T.take 4 v <> "****"

-- | Read a file when present and readable; 'Nothing' otherwise.
tryRead :: FilePath -> IO (Maybe Text)
tryRead fp = do
  r <- try (TIO.readFile fp) :: IO (Either IOException Text)
  return $ case r of
    Left _  -> Nothing
    Right t -> Just t
