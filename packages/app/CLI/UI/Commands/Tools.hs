{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 工具与工作区命令：工具/权限/用量列表、diff、历史、复制、粘贴、
-- 本地 shell 与自定义命令执行、工作目录切换。
--
-- 领域模块之一（约定见 "UI.Commands.Env"）。
module UI.Commands.Tools
  ( runTools
  , runLocalShell
  , readProviderKey
  , gitCount
  , jsonStr
  , jsonMaybeStr
  ) where

import Data.Aeson (Object, Value(..), decode, object, (.=))
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as BSL
import Core.Types
import Bridge.Scheduler (SchedulerBridge, listPlugins, listSessions, createSession, deleteSession, sendMessage, sendMessageWithUsage, sendMessageWithEffort, listModels, listProviders, planStep, approvePlan, denyPlan, denyPlanWithReason, subscribeSessionEvents, submitPlan, decideStep, fetchPlan, fetchSessionInfo, fetchAgents, renameSession, tagSession, fetchSessionMode, applySessionMode, reportStep, fetchBalance, fetchUsageStats, UsageRow(..), compactSession, retrySession, btwAsk, recapSession, queueMessage, fetchQueue, steerSession, forkSession, branchSession, setSessionCwd, setInUseProvider, startLoop, fetchLoops, stopLoops, listWorkflows, runWorkflow, fetchServiceStatus, probeProvider, listTools, fetchPermissions, getMessages)
import Core.Currency (CurrencyTable(..), loadCurrency, saveCurrency)
import Core.Replay (ReplayBlock(..), renderReplay, renderReplayText)
import Core.TurnStats
  ( Prices(..), pricesAt, pricesForModel, pricesPeakForModel, turnSummary )
import Data.Time.Clock (getCurrentTime)
import Core.SessionSummary (SessionSummary(..), pickLocalSession)
import Core.ProjectStore (ProjectSession(..), projectSessions)
import Control.Exception (IOException, try)
import qualified Data.Map as Map
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (lookupEnv, getEnvironment)
import Data.Maybe (fromMaybe)
import Core.Clipboard (saveClipboardImage)
import System.Directory (doesFileExist, getHomeDirectory)
import System.FilePath ((</>))
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode, readCreateProcessWithExitCode, proc, env)
import System.Timeout (timeout)
import qualified Data.Text.IO as TIO
import System.Directory (getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory)
import UI.Render.ToolCard (ToolStatus(..), toolCardWithStatus)
import UI.Commands.Env (CmdEnv(..))
import UI.Commands.Plan (runPlan)
import UI.Commands.Registry
import UI.Stash (Stash(..), stashPush, stashPop, stashEntries, loadStash, saveStash)
import UI.Skills (Skill(..), scanSkills, skillDirs)
import UI.InputHistory (HistState(..), loadHistory)
import UI.CustomCommands (CustomCommand(..), loadCustomCommands, renderCustomCommand)
import UI.Theme (Theme(..), themes, themeNames, resolveTheme)
import UI.I18n (Lang(..), langName, parseLang, tr)
import Config.Settings (resolveConfig)

runTools :: CmdEnv -> Command -> Maybe (IO (Maybe Text))
runTools env = go
  where
    lang       = ceLang env
    bridge     = ceBridge env
    sessionRef = ceSession env
    modelRef   = ceModel env

    go (RunShell cmd)
      | T.null (T.strip cmd) = Just $ return $ Just "Usage: /shell <cmd>"
      | otherwise = Just $ do
          r <- runLocalShell cmd
          return $ Just $ case r of
            Left e -> e
            Right (code, out, err) ->
              let body   = T.take 20000 (T.pack (out <> err))
                  suffix = case code of
                    ExitSuccess   -> ""
                    ExitFailure n -> "\n(exit " <> T.pack (show n) <> ")"
              in "$ " <> cmd <> "\n" <> body <> suffix

    go CopyLast = Just $
      return $ Just "Copy is available in the TUI (run: trha tui, then /copy)"

    go ShowDiff = Just $ do
      r <- try (readProcessWithExitCode "git" ["diff", "--no-color"] "")
             :: IO (Either IOException (ExitCode, String, String))
      return $ Just $ case r of
        Left e -> tr lang "git not available: " <> T.pack (show e)
        Right (_, out, _)
          | null (dropWhile (== '\n') out) -> tr lang "No uncommitted changes."
          | otherwise -> T.take 4000 (T.pack out)

    go ShowStats = Just $ do
      now <- getCurrentTime
      rows <- fetchUsageStats bridge
      cur <- readIORef sessionRef
      home <- getHomeDirectory
      transcript <- case cur of
        Nothing -> pure []
        Just sid -> do
          let p = home </> ".trha" </> "sessions" </> sid </> "transcript.jsonl"
          ok <- doesFileExist p
          if not ok
            then pure []
            else do
              content <- TIO.readFile p
              pure [tr lang "  transcript lines: " <> T.pack (show (length (T.lines content)))]
      pure $ Just $ T.unlines $ case rows of
        Left err -> [tr lang "Failed to read usage stats: " <> T.pack (show err)] <> transcript
        Right [] -> [tr lang "No usage recorded yet."] <> transcript
        Right rs ->
          ( tr lang "Usage per session mode (hit% = cache hit / (hit + miss), same split the invoice uses):"
            : ("mode" `pad` 10 <> "requests" `pad` 9 <> "prompt" `pad` 14
                 <> "hit%" `pad` 8 <> "out" `pad` 10 <> "resets" `pad` 8 <> "cost")
            : map (fmtRow now) rs
          ) <> transcript
      where
        pad t n = T.justifyLeft n ' ' t
        fmtRow now r = pad (urMode r) 10
          <> pad (T.pack (show (urRequests r))) 9
          <> pad (T.pack (show (urPrompt r))) 14
          <> pad (pct (urHitRatio r)) 8
          <> pad (T.pack (show (urCompletion r))) 10
          <> pad (T.pack (show (urResets r))) 8
          <> costText now r
        pct ratio = T.pack (show (fromIntegral (round (ratio * 10000) :: Int) / 100 :: Double)) <> "%"
        -- The scheduler only prices a row when TRHA_PRICE_* is configured. Fall
        -- back to the built-in DeepSeek table and mark it as an estimate (≈), so a
        -- missing env var never makes the number look authoritative.
        costText now r
          | urCost r == "—" || T.null (urCost r) = "≈¥" <> money (estimateCost now r)
          | otherwise = "¥" <> urCost r
        estimateCost now r =
          let p = pricesAt now (pricesForModel "deepseek") (pricesPeakForModel "deepseek")
          in ( fromIntegral (urCacheMiss r) * priceInput p
               + fromIntegral (urCacheHit r) * priceCached p
               + fromIntegral (urCompletion r) * priceOutput p ) / 1e6
        money x = T.pack (show (fromIntegral (round (x * 10000) :: Int) / 10000 :: Double))

    go (ChangeDir dir)
      | T.null (T.strip dir) = Just $ return $ Just (tr lang "Usage: /cd <path>")
      | otherwise = go (Workspace (Just (T.strip dir)))

    -- | @/tools [mode]@：列出调度器的工具目录。

    go (ShowTools arg) = Just $ do
      let mmode = case T.words arg of
            (m : _) -> Just m
            _       -> Nothing
      r <- listTools bridge mmode
      return $ Just $ case r of
        Left e -> tr lang "Error: " <> T.pack (show e)
        Right defs
          | null defs -> tr lang "No tools registered."
          | otherwise -> T.unlines (tr lang "Tools:" : map renderTool defs)
      where
        renderTool (Object o) =
          "  - " <> jsonStr "name" o
            <> maybe "" (\d -> " — " <> d) (jsonMaybeStr "description" o)
        renderTool v = "  - " <> T.pack (show v)

    -- | @/permissions@：权限规则的只读视图。

    go ShowPermissions = Just $ do
      r <- fetchPermissions bridge
      return $ Just $ case r of
        Left e -> tr lang "Error: " <> T.pack (show e)
        Right rules
          | null rules -> tr lang "No permission rules."
          | otherwise -> T.unlines (tr lang "Permission rules:" : map renderRule rules)
      where
        renderRule (Object o) = "  - " <> jsonStr "kind" o <> ": " <> jsonStr "pattern" o
        renderRule v = "  - " <> T.pack (show v)

    -- | @/history@：最近的输入历史（与 TUI 共用 @~/.trha/history@）。

    go ShowHistory = Just $ do
      hs <- loadHistory
      let entries = take 20 (hsHistory hs)
      return $ Just $ if null entries
        then tr lang "No input history yet."
        else T.unlines (tr lang "Recent input:" : map ("  " <>) entries)

    -- | @/about@：版本、工作区与运行时信息。
    -- | @/forget <text>@：删除匹配的备注。

    go (Workspace mdir) = Just $ do
      cur <- readIORef sessionRef
      case cur of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> case mdir of
          Nothing -> return $ Just (tr lang "Usage: /workspace <absolute-path>")
          Just dir -> do
            r <- setSessionCwd bridge sid (T.unpack (T.strip dir))
            return $ Just $ case r of
              Left e  -> tr lang "Error: " <> T.pack (show e)
              Right p -> tr lang "Workspace: " <> T.pack p

    go (Paste text) = Just $ do
      r <- saveClipboardImage
      return $ Just $ case r of
        Nothing -> tr lang "No image in clipboard"
        Just path -> tr lang "Image saved: " <> T.pack path
          <> (if T.null (T.strip text) then "" else " (" <> T.strip text <> ")")

    go ShowUsage = Just $ do
      bal <- fetchBalance bridge
      cfg <- resolveConfig defaultCLIConfig
      return $ Just $ T.unlines
        [ tr lang "Usage:"
        , tr lang "  model: " <> configModel cfg
        , tr lang "  balance: " <> either (const (tr lang "unavailable"))
            (\b -> balanceCurrency b <> " " <> T.pack (show (balanceTotal b))) bal
        ]

    go (RunCustom name args) = Just $ do
      cmds <- loadCustomCommands
      case [ cc | cc <- cmds, ccName cc == name ] of
        (cc : _) -> fromMaybe (return Nothing) $
                      runPlan env (SendMessage (renderCustomCommand cc args))
        [] -> return $ Just $ tr lang "Unknown command: /" <> name

    go _ = Nothing

runLocalShell :: Text -> IO (Either Text (ExitCode, String, String))
runLocalShell cmd = do
  r <- timeout 120000000 $ do
    mSpec <- lookupEnv "ComSpec"
    let (sh, shArgs) = case mSpec of
          Just spec -> (spec, ["/c", T.unpack cmd])
          Nothing   -> ("bash", ["-lc", T.unpack cmd])
    baseEnv <- getEnvironment
    let overrides = [("NO_COLOR", "1"), ("TERM", "dumb")
                    , ("PAGER", "cat"), ("GIT_PAGER", "cat")]
        childEnv  = [kv | kv <- baseEnv
                    , fst kv `notElem` map fst overrides] ++ overrides
        cp = (proc sh shArgs) { env = Just childEnv }
    try (readCreateProcessWithExitCode cp "")
      :: IO (Either IOException (ExitCode, String, String))
  return $ case r of
    Nothing         -> Left "shell: timed out after 120s"
    Just (Left e)   -> Left ("shell: " <> T.pack (show e))
    Just (Right ok) -> Right ok

readProviderKey :: Text -> IO (Maybe Text)
readProviderKey name = do
  home <- getHomeDirectory
  let path = home </> ".trha" </> "provider-keys.json"
  ok <- doesFileExist path
  if not ok
    then return Nothing
    else do
      raw <- BSL.readFile path
      return $ case decode raw of
        Just (Object o) -> case KeyMap.lookup "keys" o of
          Just (Object ks) -> case KeyMap.lookup (AesonKey.fromText name) ks of
            Just (String k) -> Just k
            _ -> Nothing
          _ -> Nothing
        _ -> Nothing

gitCount :: (ExitCode, String, String) -> Text
gitCount (_, out, _) = T.strip (T.pack out)

jsonStr :: Text -> Object -> Text
jsonStr k o = fromMaybe "" (jsonMaybeStr k o)

jsonMaybeStr :: Text -> Object -> Maybe Text
jsonMaybeStr k o = case KeyMap.lookup (AesonKey.fromText k) o of
  Just (String s) -> Just s
  _               -> Nothing
