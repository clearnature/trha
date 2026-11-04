{-# LANGUAGE OverloadedStrings #-}

-- | Bridge from the CLI/TUI shell to the TypeScript orchestration layer
-- (packages/scheduler).  Wire protocol (Phase 2 S0 alignment):
--
--   POST   /api/session/start       {mode}          -> {sessionId, mode}
--   GET    /api/sessions                            -> [ {id, mode, ...} ]
--   GET    /api/session/:id                         -> {id, mode, messages, ...}
--   DELETE /api/session/:id                         -> 200
--   POST   /api/agent/step          {sessionId,message} -> {reply, messages, mode}
--   POST   /api/session/:id/interrupt               -> {aborted}
--   GET    /api/session/:id/messages                -> {messages: [{role, content}]}
--   GET    /api/models                              -> [ {name, description, contextSize} ]
--   GET    /health                                  -> {status, ...}
--
-- Functions that have no counterpart in the orchestration API return an
-- explicit 'UnknownCLIError' instead of pretending to work.
module Bridge.Scheduler
  ( -- * Scheduler Bridge
    SchedulerBridge(..)
  , createSchedulerBridge

    -- * Session Operations
  , createSession
  , listSessions
  , getSession
  , deleteSession

    -- * Message Operations
  , sendMessage
  , sendMessageWithUsage
  , sendMessageWithTarget
  , sendMessageWithTargetEffort
  , sendMessageWithEffort
  , getMessages
  , allowAlways
  , interruptSession
  , fetchTeamTasks
  , SessionInfo(..)
  , fetchSessionInfo
  , fetchAgents
  , renameSession
  , tagSession
  , fetchServiceStatus
  , fetchBalance
  , fetchUsageStats
  , UsageRow(..)
  , transcribeVoice
  , compactSession
  , retrySession
  , btwAsk
  , recapSession
  , queueMessage
  , fetchQueue
  , steerSession
  , forkSession
  , branchSession
  , setInUseProvider
  , setSandboxConfig
  , fetchSandboxConfig
  , submitExperiment
  , setSessionCwd
  , startLoop
  , fetchLoops
  , stopLoops
  , listWorkflows
  , runWorkflow
  , SessionMode(..)
  , fetchSessionMode
  , applySessionMode
  , listProviders
  , probeProvider
  , ProviderProbe(..)
  , saveProvider
  , removeProvider

    -- * Session Events (SSE, Phase 2 S2)
  , subscribeSessionEvents
  , subscribeSessionEventsWith
  , subscribeSessionEventsWithTerminal

    -- * Plan / Approval (Phase 2 S1)
  , planStep
  , approvePlan
  , denyPlan
  , denyPlanWithReason

    -- * Multi-step plans (kernel-owned)
  , submitPlan
  , fetchPlan
  , decideStep
  , decidePlan
  , reportStep

    -- * Agent Operations
  , getAgentState
  , updateAgentState

    -- * Model Operations
  , listModels
  , getModel

    -- * Plugins (Phase 3)
  , listPlugins
  , listTools
  , fetchPermissions

    -- * Health Check
  , healthCheck
  ) where

import Bridge.Scheduler.Core (SchedulerBridge(..), createSchedulerBridge)
import Bridge.Scheduler.Session
  ( SessionInfo(..), allowAlways, applySessionMode, branchSession, btwAsk
  , compactSession, createSession, deleteSession, fetchQueue, fetchSessionInfo
  , fetchSessionMode, fetchTeamTasks, forkSession, getMessages, getSession
  , interruptSession, listSessions, queueMessage, recapSession, renameSession
  , retrySession, sendMessage, sendMessageWithEffort, sendMessageWithTarget
  , sendMessageWithTargetEffort, sendMessageWithUsage, setSessionCwd, steerSession
  , subscribeSessionEvents, subscribeSessionEventsWith
  , subscribeSessionEventsWithTerminal, tagSession )
import Bridge.Scheduler.Admin
  ( UsageRow(..), fetchAgents, fetchBalance, fetchLoops, fetchPermissions
  , fetchSandboxConfig, fetchServiceStatus, fetchUsageStats, healthCheck
  , listPlugins, listTools, listWorkflows, runWorkflow, setSandboxConfig
  , startLoop, stopLoops, submitExperiment, transcribeVoice )
import Bridge.Scheduler.Plan
  ( approvePlan, decidePlan, decideStep, denyPlan, denyPlanWithReason, fetchPlan
  , getAgentState, planStep, reportStep, submitPlan, updateAgentState )
import Bridge.Scheduler.Model
  ( ProviderProbe(..), getModel, listModels, listProviders, probeProvider
  , removeProvider, saveProvider, setInUseProvider )
import Config.Settings (resolveConfig)
import Core.Types
import Core.RunState (RuntimeEntry(..), Service(..), readRuntimeEntry)
import Core.HTTP
import Core.SSE (SseDecoder, SsePayload(..), SseNotice(..), classifyPayload, toNotice, feed, newDecoder)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseMaybe, (.:), (.:?), (.!=))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (join, void, when)
import Data.Maybe (fromMaybe)
import System.Directory (getCurrentDirectory)
import System.Timeout (timeout)
import Control.Exception (SomeAsyncException, SomeException, catch, fromException, throwIO)
import Data.Text (Text)
import qualified Data.Vector as V
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client
    ( BodyReader, HttpException(..), managerResponseTimeout, managerSetProxy, newManager, noProxy
    , parseRequest, requestHeaders, responseBody, responseTimeoutNone, withResponse, brRead
    )
import Network.HTTP.Types (HeaderName)

-- | Scheduler bridge
-- Session Operations
--------------------------------------------------------------------------------






















