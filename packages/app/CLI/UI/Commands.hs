{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | REPL command executor.  Command types and parsing live in the pure
-- "UI.Commands.Registry" (single source of truth shared with the TUI
-- quick picker and tab completion); this module implements the IO side.
module UI.Commands
  ( -- * Re-exported registry
    module UI.Commands.Registry
    -- * Execution
  , executeCommand
    -- * Shared settings runner (REPL + TUI)
  , runSettingsCommand
    -- * Shared local-shell runner (REPL + TUI)
  , runLocalShell
    -- * Resume candidates (local transcripts ∪ scheduler sessions)
  , resumeSessions
  , resumeMessages
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
import Core.ProjectStore (ProjectSession(..), projectSessions)
import qualified Data.Map as Map
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath ((</>))
import System.Exit (ExitCode(..))
import System.Process (env)
import qualified Data.Text.IO as TIO
import System.FilePath ((</>), takeDirectory)
import UI.Render.ToolCard (ToolStatus(..), toolCardWithStatus)
import UI.Commands.Registry
import UI.Stash (Stash(..), stashPush, stashPop, stashEntries, loadStash, saveStash)
import UI.Skills (Skill(..), scanSkills, skillDirs)
import UI.InputHistory (HistState(..), loadHistory)
import UI.CustomCommands (CustomCommand(..), loadCustomCommands, renderCustomCommand)
import UI.Theme (Theme(..), themes, themeNames, resolveTheme)
import UI.Commands.Env (CmdEnv(..), dispatch)
import UI.Commands.Meta (runMeta)
import UI.Commands.Config (runConfig, runSettingsCommand)
import UI.Commands.Integration (runIntegration)
import UI.Commands.Model (runModel)
import UI.Commands.Plan (runPlan)
import UI.Commands.Tools (runLocalShell, runTools)
import UI.Commands.Session (resumeMessages, resumeSessions, runSession)
import UI.I18n (Lang(..), langName, parseLang, tr)

-- | Handle @/settings@ outside the interactive loop: read the effective
-- configuration, then either print it or apply+persist one key.  Shared by
-- the REPL executor and the TUI so both surfaces behave identically.

executeCommand :: Lang -> SchedulerBridge -> IORef (Maybe SessionId) -> IORef Text -> Command -> IO (Maybe Text)
-- | Parse a loop interval: @30s@, @5m@, @1h@, or plain seconds.

executeCommand lang bridge sessionRef modelRef cmd
  | Just act <- dispatch [runMeta, runModel, runSession, runConfig, runIntegration, runTools, runPlan] env cmd = act
  where env = CmdEnv lang bridge sessionRef modelRef


executeCommand _ _ _ _ cmd =
  return $ Just ("Command not available in this front-end: " <> T.pack (show cmd))

-- | 快照文件名 @&lt;stamp&gt;-&lt;sha1前8位&gt;-&lt;basename&gt;@ 里取 basename。
-- stamp 自己也含 @-@，所以按「第一个 8 位十六进制段」定位分隔点。

-- | 在 root 下按文件名找文件（跳过 .git/依赖目录，深度上限 6）。

-- | 从 @~/.trha/provider-keys.json@ 读一个 provider 的 key（只在本机进程内用）。

-- | @git rev-list --count@ 的输出。

-- | 可恢复会话 = 本地 transcript ∪ 调度层（stateDir 恢复的）会话。
--
-- 本地有的带标题与轮次；只在调度层存在的补一条最小摘要——它没有本地
-- transcript，历史由 'resumeMessages' 从调度层拉回来。

-- | 取 JSON 对象的可选字符串字段。
