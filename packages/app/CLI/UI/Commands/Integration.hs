{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 外部集成与知识类命令：MCP/LSP/Hooks/插件/技能/代理、记忆与备忘、
-- 依赖图与会话树、待办与目标、工作流、代码审阅、项目初始化。
--
-- 领域模块之一（约定见 "UI.Commands.Env"）。
module UI.Commands.Integration
  ( runIntegration
  ) where

import Data.Aeson (Object, Value(..), decode, object, (.=))
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as BSL
import Core.Types
import Bridge.Scheduler (SchedulerBridge, listPlugins, listSessions, createSession, deleteSession, sendMessage, sendMessageWithUsage, sendMessageWithEffort, listModels, listProviders, planStep, approvePlan, denyPlan, denyPlanWithReason, subscribeSessionEvents, submitPlan, decideStep, fetchPlan, fetchSessionInfo, fetchAgents, renameSession, tagSession, fetchSessionMode, applySessionMode, reportStep, fetchBalance, fetchUsageStats, UsageRow(..), compactSession, retrySession, btwAsk, recapSession, queueMessage, fetchQueue, steerSession, forkSession, branchSession, setSessionCwd, setInUseProvider, startLoop, fetchLoops, stopLoops, listWorkflows, runWorkflow, fetchServiceStatus, probeProvider, listTools, fetchPermissions, getMessages)
import Core.Currency (CurrencyTable(..), loadCurrency, saveCurrency)
import Core.Replay (ReplayBlock(..), renderReplay, renderReplayText)
import Core.TurnStats (Prices(..), pricesForModel, turnSummary)
import Core.SessionSummary (SessionSummary(..), pickLocalSession)
import Core.Memory (allMemories, forgetText, rememberText)
import Core.ProjectStore (ProjectSession(..), projectSessions)
import Core.Transcript (loadTranscript)
import qualified Data.Map as Map
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Data.Maybe (fromMaybe)
import System.Directory (doesDirectoryExist, doesFileExist, getHomeDirectory, listDirectory)
import System.FilePath ((</>))
import System.Exit (ExitCode(..))
import System.Process (readCreateProcessWithExitCode, proc, env)
import qualified Data.Text.IO as TIO
import System.Directory (getHomeDirectory)
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
import UI.Render.Sidebar (agentTreeLines)
import System.Directory (getCurrentDirectory)
import UI.I18n (Lang(..), langName, parseLang, tr)

runIntegration :: CmdEnv -> Command -> Maybe (IO (Maybe Text))
runIntegration env = go
  where
    lang       = ceLang env
    bridge     = ceBridge env
    sessionRef = ceSession env
    modelRef   = ceModel env

    go Skills = Just $ do
      cwd <- getCurrentDirectory
      dirs <- skillDirs cwd
      skills <- scanSkills dirs
      return $ Just $ if null skills
        then "No skills found (put SKILL.md under .agents/skills or .trha/skills)."
        else T.unlines [ "  • " <> skName s <> " — " <> skDescription s | s <- skills ]

    go Todo = Just $ do
      msid <- readIORef sessionRef
      case msid of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> do
          r <- fetchSessionInfo bridge sid
          return $ Just $ case r of
            Right info
              | null (siTodos info) -> tr lang "No tasks"
              | otherwise -> T.unlines
                  [ "  " <> glyph (todoStatus i) <> " " <> todoSubject i | i <- siTodos info ]
            Left e -> T.pack (show e)
      where
        glyph TodoPending    = "○"
        glyph TodoInProgress = "◐"
        glyph TodoDone       = "●"

    go Tree = Just $ do
      r <- fetchAgents bridge
      return $ Just $ case r of
        Right [] -> "no agents"
        Right as -> T.unlines (agentTreeLines Nothing as)
        Left e   -> T.pack (show e)

    go ShowMemory = Just $ do
      entries <- allMemories
      if null entries
        then return $ Just $ tr lang "No memory notes yet (use /remember <text>)."
        else return $ Just $ T.intercalate "\n\n"
               [ "# " <> name <> "\n" <> body | (name, body) <- entries ]

    go (Workflow arg) = Just $ do
      cur <- readIORef sessionRef
      case cur of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> case T.words (T.strip arg) of
          [] -> do
            r <- listWorkflows bridge
            return $ Just $ case r of
              Left e -> tr lang "Error: " <> T.pack (show e)
              Right [] -> tr lang "No workflows."
              Right ws -> T.unlines
                (tr lang "Workflows:" : [ "  " <> n <> "  " <> d | (n, d) <- ws ])
          (name : rest) -> do
            r <- runWorkflow bridge sid name (T.unwords rest)
            return $ Just $ case r of
              Left e -> tr lang "Error: " <> T.pack (show e)
              Right reply -> reply

    go Graph = Just $ do
      agents <- fetchAgents bridge
      cur <- readIORef sessionRef
      rows <- maybe (pure []) loadTranscript cur
      let blocks = renderReplay rows
          tools = [ nm | ReplayBlock { rbTool = Just (nm, _) } <- blocks ]
          counts = Map.toList (Map.fromListWith (+) [ (nm, 1 :: Int) | nm <- tools ])
          tree = case agents of
            Left e -> [ "  ! " <> T.pack (show e) ]
            Right as -> [ "  - " <> aeId a | a <- as ]
      return $ Just $ T.unlines $
        [ tr lang "Graph:", tr lang "  session: " <> maybe "-" T.pack cur ]
        ++ [ "  - " <> T.pack nm <> " x" <> T.pack (show n) | (nm, n) <- counts ]
        ++ tree

    go GoalView = Just $ do
      cur <- readIORef sessionRef
      case cur of
        Nothing -> return $ Just (tr lang "No active session.")
        Just sid -> do
          info <- fetchSessionInfo bridge sid
          return $ Just $ case info of
            Left e -> tr lang "Error: " <> T.pack (show e)
            Right si -> T.unlines
              [ tr lang "Goal: " <> fromMaybe (tr lang "none") (siGoal si)
              , tr lang "Todos: " <> T.pack (show (length (siTodos si)))
              ]

    go (Forget text)
      | T.null (T.strip text) = Just $ return $ Just (tr lang "Usage: /forget <text>")
      | otherwise = Just $ do
          n <- forgetText (T.strip text)
          return $ Just $ tr lang "Forgot " <> T.pack (show n) <> tr lang " note line(s)."

    -- | @/reload-plugins@：重扫用户命令；scheduler 的插件目录本来就有 watcher。

    go ReloadPlugins = Just $ do
      cmds <- loadCustomCommands
      return $ Just $ tr lang "Reloaded user commands: " <> T.pack (show (length cmds))
                       <> tr lang " (scheduler plugins hot-reload automatically)"

    -- | @/init@：项目里没有 AGENTS.md 时写一份骨架；已有就不动它。

    go InitProject = Just $ do
      cwd <- getCurrentDirectory
      let target = cwd </> "AGENTS.md"
      exists <- doesFileExist target
      if exists
        then return $ Just $ tr lang "AGENTS.md already exists: " <> T.pack target
        else do
          TIO.writeFile target initSkeleton
          return $ Just $ tr lang "Wrote " <> T.pack target
                           <> tr lang " — fill in build, test and conventions."

    -- | @/review [path]@：把工作区（含已暂存）的 diff 交给模型评审。

    go (Review arg) = Just $ do
      cwd <- getCurrentDirectory
      let git xs = readCreateProcessWithExitCode (proc "git" ("-C" : cwd : xs)) ""
          paths = map T.unpack (T.words arg)
      (probeOut, _, _) <- git ["rev-parse", "--show-toplevel"]
      case probeOut of
        ExitFailure _ -> return $ Just $ tr lang "Not a git checkout: " <> T.pack cwd
        ExitSuccess -> do
          (_, unstaged, _) <- git (["diff"] <> paths)
          (_, staged, _) <- git (["diff", "--cached"] <> paths)
          let diffText = T.pack (unstaged <> staged)
              clipped = if T.length diffText > 40000
                          then T.take 40000 diffText <> "\n… (truncated)"
                          else diffText
          if T.null (T.strip diffText)
            then return $ Just (tr lang "No uncommitted changes to review.")
            else fromMaybe (return Nothing) $
                   runPlan env
                     (SendMessage ("请审阅以下未提交的改动，指出问题与改进点：\n\n```diff\n"
                                   <> clipped <> "\n```"))

    go ShowMcp = Just $ do
      (_, mcp) <- fetchServiceStatus bridge
      return $ Just $ T.unlines (tr lang "MCP:" : map ("  " <>) mcp)

    go ShowLsp = Just $ do
      (lsp, _) <- fetchServiceStatus bridge
      return $ Just $ T.unlines (tr lang "LSP:" : map ("  " <>) lsp)

    go ShowHooks = Just $ do
      home <- getHomeDirectory
      let dir = home </> ".trha" </> "hooks"
      ok <- doesDirectoryExist dir
      if not ok
        then return $ Just (tr lang "No hooks.")
        else do
          fs <- listDirectory dir
          return $ Just $ if null fs
            then tr lang "No hooks."
            else T.unlines (tr lang "Hooks:" : map T.pack fs)

    go (Remember text) = Just $
      if T.null (T.strip text)
        then return $ Just $ tr lang "Usage: /remember <text>"
        else do
          rememberText text
          return $ Just $ tr lang "Remembered: " <> T.strip text

    go Plugins = Just $ do
      result <- listPlugins bridge
      return $ Just $ case result of
        Right [] -> tr lang "No plugins registered."
        Right ps -> (tr lang "Plugins:" <> "\n") <> T.unlines
          [ "  - " <> pluginName p <> " " <> pluginVersion p
              <> maybe "" (\d -> "  —  " <> d) (Just (pluginDescription p))
          | p <- ps ]
        Left err -> tr lang "Error: " <> T.pack (show err)

    go Agents = Just $ do
      r <- fetchAgents bridge
      return $ Just $ case r of
        Left err -> tr lang "Error: " <> T.pack (show err)
        Right as -> T.unlines (tr lang "Agents:" : [ "  - " <> aeId a | a <- as ])

    go _ = Nothing

-- | @/init@ 写出的 AGENTS.md 骨架。
initSkeleton :: Text
initSkeleton = T.unlines
  [ "# AGENTS.md"
  , ""
  , "本文件是 agent 的入口。请按项目实际情况补充下面几节。"
  , ""
  , "## 项目概况"
  , ""
  , "## 构建与测试"
  , ""
  , "```bash"
  , "# 构建命令"
  , "```"
  , ""
  , "## 约定"
  , ""
  ]

-- | Map the wire tool status to the card status type.

-- | One plan decision, rendered as a compact list.
