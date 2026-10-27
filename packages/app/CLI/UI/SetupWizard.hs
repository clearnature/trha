{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Interactive @trha setup@ wizard.
--
-- Modelled on the setup flows of the reference CLIs (@claude@, @codex@,
-- @dsh@, @reasonix@): ask a short sequence of questions with the current
-- value as the default, write the same files the runtime reads, and finish
-- with a summary.  Directories are created here (the startup path only
-- guarantees @~/.trha@ and @settings.yaml@).
--
-- Everything decidable without a terminal lives in "UI.Setup"; this module
-- is the thin I/O shell around it.
module UI.SetupWizard (runSetupWizard) where

import Control.Exception (IOException, catch, try)
import Control.Monad (forM_)
import Data.Bits ((.&.))
import Data.List (find)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Console.Haskeline (defaultSettings, getPassword, runInputT)
import System.Directory (doesFileExist)
import System.Exit (ExitCode(..))
import System.IO (hFlush, hIsTerminalDevice, stdin, stdout)
import System.Posix.Files (FileStatus, fileMode, getFileStatus)
import System.Process (readProcessWithExitCode)

import API.Providers (loadKeys, loadProviderStore, providerFilePath, saveKeys, saveProviderStore)
import Config.Home (initHomeDirs)
import Config.Settings (getConfigDir, getHomeConfigPath, saveConfig)
import Core.Provider.Types
    ( ProviderDraft(..), ProviderStore(..), draftToEntry, insertKey, lookupKey
    , peHasKey, peName, upsertProvider )
import Core.Types (CLIConfig(..))
import UI.I18n (Lang, tr)
import UI.ProviderPresets (Preset(..), presets)
import UI.Setup

-- | Run the wizard; returns the configuration that is now in effect.
--
-- @nonInteractive@ (from @--yes@) or a non-terminal stdin skips every
-- question and only creates the directory skeleton.
runSetupWizard :: Lang -> Bool -> CLIConfig -> IO CLIConfig
runSetupWizard lang nonInteractive cfg0 = do
  dir <- getConfigDir
  created <- initHomeDirs dir
  TIO.putStrLn (tr lang "trha setup — initialise ~/.trha")
  TIO.putStrLn (tr lang "Home directory: " <> T.pack dir)
  TIO.putStrLn (tr lang "Standard directories are in place" <> " ("
                <> T.pack (show (length created)) <> " " <> tr lang "created" <> ")")
  tty <- hIsTerminalDevice stdin
  cfg <- if nonInteractive || not tty
    then do
      TIO.putStrLn (tr lang "No terminal; keeping the current settings.")
      saveConfig cfg0
      settingsPath <- getHomeConfigPath
      TIO.putStrLn (tr lang "Setup complete. Settings: " <> T.pack settingsPath)
      pure cfg0
    else do
      answers <- askAnswers lang cfg0
      let answered = applyAnswers cfg0 answers
      saveConfig answered
      writeProvider answers
      settingsPath <- getHomeConfigPath
      providersFile <- providerFilePath
      TIO.putStrLn ""
      TIO.putStrLn (tr lang "Setup complete. Settings: " <> T.pack settingsPath)
      TIO.putStrLn (tr lang "Provider: " <> T.pack providersFile)
      forM_ (setupSummary answered) (TIO.putStrLn . ("  " <>))
      pure answered
  TIO.putStrLn ""
  TIO.putStrLn (tr lang "Self-check:")
  checks <- runLocalChecks lang cfg
  mapM_ (TIO.putStrLn . renderCheck) checks
  TIO.putStrLn (tr lang "Next: run trha for the TUI, or trha cli for the REPL.")
  pure cfg

--------------------------------------------------------------------------------
-- Questions
--------------------------------------------------------------------------------

askAnswers :: Lang -> CLIConfig -> IO SetupAnswers
askAnswers lang cfg = do
  l  <- askChoice lang (tr lang "Interface language") langChoices (configLang cfg)
  th <- askChoice lang (tr lang "Theme") themeChoices (configTheme cfg)
  r  <- askChoice lang (tr lang "Reasoning language") reasoningChoices (configReasoningLanguage cfg)
  (prov, model, key) <- askProvider lang cfg
  pure emptyAnswers
    { saLang = l, saTheme = th, saReasoning = r
    , saProvider = prov, saModel = model, saApiKey = key }

-- | Numbered choice; blank keeps the current value.
askChoice :: Lang -> Text -> [Text] -> Text -> IO (Maybe Text)
askChoice lang title choices current = do
  TIO.putStrLn ""
  TIO.putStrLn (title <> "  (" <> tr lang "current: " <> current <> ")")
  forM_ (zip [1 :: Int ..] choices) $ \(i, c) ->
    TIO.putStrLn ("  " <> T.pack (show i) <> ") " <> c)
  answer <- askLine (tr lang "Choose [blank = keep]: ")
  pure (choiceAt choices answer)

-- | Provider, its model, and an optional API key.
askProvider :: Lang -> CLIConfig -> IO (Maybe Text, Maybe Text, Maybe Text)
askProvider lang cfg = do
  TIO.putStrLn ""
  TIO.putStrLn (tr lang "Choose the model provider"
                 <> "  (" <> tr lang "current: "
                 <> (if T.null (T.strip (configProvider cfg)) then "—" else configProvider cfg) <> ")")
  forM_ (zip [1 :: Int ..] presets) $ \(i, p) ->
    TIO.putStrLn ("  " <> T.pack (show i) <> ") " <> preName p <> "  " <> preBaseUrl p)
  TIO.putStrLn ("  0) " <> tr lang "keep current")
  answer <- askLine (tr lang "Choose [blank = keep]: ")
  case choiceAt providerChoices answer of
    Nothing -> pure (Nothing, Nothing, Nothing)
    Just name -> do
      let mpreset = find ((== name) . preName) presets
          models = maybe [] preModels mpreset
      model <- askModel lang models
      key <- askPassword lang
      pure (Just name, model, key)

askModel :: Lang -> [Text] -> IO (Maybe Text)
askModel _ [] = pure Nothing
askModel lang models = do
  TIO.putStrLn ""
  forM_ (zip [1 :: Int ..] models) $ \(i, m) ->
    TIO.putStrLn ("  " <> T.pack (show i) <> ") " <> m)
  answer <- askLine (tr lang "Model [blank = first]: ")
  pure (Just (fromMaybe (fromMaybe "" (listToMaybe models)) (choiceAt models answer)))

askPassword :: Lang -> IO (Maybe Text)
askPassword lang = do
  raw <- runInputT defaultSettings
           (getPassword Nothing (T.unpack (tr lang "API key (blank = keep existing): ")))
  TIO.putStrLn ""
  pure $ case raw of
    Just s | not (T.null (T.strip (T.pack s))) -> Just (T.strip (T.pack s))
    _ -> Nothing

askLine :: Text -> IO Text
askLine prompt = do
  TIO.putStr prompt
  hFlush stdout
  line <- getLine `catch` \(_ :: IOException) -> pure ""
  pure (T.pack line)

--------------------------------------------------------------------------------
-- Self-check
--------------------------------------------------------------------------------

-- | Local checks that do not need the scheduler: directory permissions,
-- settings file, a configured provider with a key, and git.
runLocalChecks :: Lang -> CLIConfig -> IO [CheckItem]
runLocalChecks lang cfg = do
  dir <- getConfigDir
  homeOk <- modeIs0700 dir
  settingsPath <- getHomeConfigPath
  settingsOk <- doesFileExist settingsPath
  ProviderStore ps <- loadProviderStore
  keys <- loadKeys
  let name
        | not (T.null (T.strip (configProvider cfg))) = T.strip (configProvider cfg)
        | (p : _) <- ps = peName p
        | otherwise = ""
      hasKey = case lookupKey name keys of
        Just k  -> not (T.null (T.strip k))
        Nothing -> maybe False peHasKey (find ((== name) . peName) ps)
      provDetail
        | T.null name = tr lang "not configured"
        | hasKey      = tr lang "key saved"
        | otherwise   = tr lang "no key"
  gitText <- gitVersion
  pure
    [ CheckItem "~/.trha (0700)" homeOk ""
    , CheckItem "settings.yaml" settingsOk ""
    , CheckItem ("provider: " <> (if T.null name then "—" else name))
        (not (T.null name)) provDetail
    , CheckItem "git" (maybe False (const True) gitText)
        (fromMaybe (tr lang "not found") gitText)
    ]

modeIs0700 :: FilePath -> IO Bool
modeIs0700 dir = do
  r <- try (getFileStatus dir) :: IO (Either IOException FileStatus)
  pure $ case r of
    Right st -> (fileMode st .&. 0o777) == 0o700
    Left _   -> False

gitVersion :: IO (Maybe Text)
gitVersion = do
  r <- try (readProcessWithExitCode "git" ["--version"] "")
         :: IO (Either IOException (ExitCode, String, String))
  pure $ case r of
    Right (ExitSuccess, out, _) ->
      let v = T.strip (T.pack out)
      in Just (fromMaybe v (T.stripPrefix "git version " v))
    _ -> Nothing

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

-- | Write the provider entry (and its key) exactly where the kernel reads it.
writeProvider :: SetupAnswers -> IO ()
writeProvider a = case saProvider a of
  Nothing -> pure ()
  Just name -> do
    let mpreset = find ((== name) . preName) presets
        models = maybe [] preModels mpreset
        model = fromMaybe (fromMaybe "" (listToMaybe models)) (saModel a)
        draft = ProviderDraft
          { pdName = name
          , pdKind = maybe "openai" preKind mpreset
          , pdBaseUrl = maybe "" preBaseUrl mpreset
          , pdApiKey = fromMaybe "" (saApiKey a)
          , pdModels = models
          , pdDefault = model
          , pdAuthHeader = True
          , pdNoProxy = False
          , pdEffort = ""
          , pdEfforts = []
          , pdHeaders = Nothing
          , pdExtraBody = Nothing
          , pdThinking = ""
          , pdResponsesMode = ""
          , pdContextWindow = Nothing
          , pdVision = []
          }
    store <- loadProviderStore
    saveProviderStore (upsertProvider (draftToEntry draft) store)
    case saApiKey a of
      Just k | not (T.null (T.strip k)) -> do
        keys <- loadKeys
        saveKeys (insertKey name (T.strip k) keys)
      _ -> pure ()
