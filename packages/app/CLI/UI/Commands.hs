{-# LANGUAGE OverloadedStrings #-}

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
  ) where

import Core.Types
import Bridge.Scheduler (SchedulerBridge, listPlugins, listSessions, createSession, deleteSession, sendMessage, listModels, listProviders, planStep, approvePlan, denyPlan, subscribeSessionEvents, submitPlan, decideStep, fetchPlan, reportStep)
import Core.Replay (renderReplay, renderReplayText)
import Core.SessionSummary (SessionSummary(..), pickLocalSession)
import Core.Transcript (listLocalSessions, loadTranscript, recordChunk, recordModelRequest, recordSession, recordToolEvent, recordUser)
import Control.Concurrent (threadDelay)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import System.Process (callCommand)
import UI.Render.ToolCard (ToolStatus(..), toolCardWithStatus)
import UI.Commands.Registry
import UI.I18n (Lang(..), tr)
import Config.Settings (resolveConfig, saveConfig)

-- | Handle @/settings@ outside the interactive loop: read the effective
-- configuration, then either print it or apply+persist one key.  Shared by
-- the REPL executor and the TUI so both surfaces behave identically.
runSettingsCommand :: Lang -> Text -> IO (Maybe Text)
runSettingsCommand lang arg =
  case T.words arg of
    [] -> do
      cfg <- resolveConfig defaultCLIConfig
      return $ Just (formatSettings lang cfg)
    (key : rest) -> do
      cfg <- resolveConfig defaultCLIConfig
      let raw = T.unwords rest
      case parseSettingValue lang cfg key raw of
        Left err    -> return $ Just err
        Right newCfg -> do
          saveConfig newCfg
          return $ Just (tr lang "Setting updated: " <> key)

-- | Execute a command
executeCommand :: Lang -> SchedulerBridge -> IORef (Maybe SessionId) -> IORef Text -> Command -> IO (Maybe Text)
executeCommand lang _ _ _ Help = return $ Just (registryHelp lang)

executeCommand _ _ _ _ Quit = return Nothing

executeCommand lang bridge _ _ Sessions = do
  result <- listSessions bridge
  return $ Just $ case result of
    Right sessions -> if null sessions
      then tr lang "No active sessions"
      else (tr lang "Sessions:" <> "\n") <> T.unlines (map (\s -> "  - " <> T.pack s) sessions)
    Left err -> tr lang "Error: " <> T.pack (show err)

executeCommand lang bridge sessionRef modelRef CreateSession = do
  result <- createSession bridge
  case result of
    Right sid -> do
      writeIORef sessionRef (Just sid)
      model <- readIORef modelRef
      recordSession sid model
      return $ Just $ tr lang "Session created: " <> T.pack sid
    Left err -> return $ Just $ tr lang "Error: " <> T.pack (show err)

executeCommand lang bridge sessionRef _ (DeleteSession sid) = do
  if null sid
    then return $ Just (tr lang "Usage: /delete <session-id>")
    else do
      result <- deleteSession bridge sid
      current <- readIORef sessionRef
      case current of
        Just currentSid | currentSid == sid -> writeIORef sessionRef Nothing
        _ -> return ()
      return $ Just $ case result of
        Right () -> tr lang "Session deleted: " <> T.pack sid
        Left err -> tr lang "Error: " <> T.pack (show err)

executeCommand lang bridge _ _ Models = do
  result <- listModels bridge
  return $ Just $ case result of
    Right models -> if null models
      then tr lang "No models available"
      else (tr lang "Models:" <> "\n") <> T.unlines (map (\m -> "  - " <> modelName m <> " (" <> modelDescription m <> ")") models)
    Left err -> tr lang "Error: " <> T.pack (show err)

executeCommand lang _ _ modelRef (SelectModel name) = do
  writeIORef modelRef name
  return $ Just $ tr lang "Model selected: " <> name

executeCommand lang _ _ modelRef ShowModel = do
  model <- readIORef modelRef
  return $ Just $ tr lang "Current model: " <> model

executeCommand lang _ _ _ Clear = do
  callCommand "clear"
  return Nothing

executeCommand lang _ sessionRef modelRef Status = do
  session <- readIORef sessionRef
  model <- readIORef modelRef
  return $ Just $ T.unlines
    [ tr lang "Status:"
    , tr lang "  Current session: " <> maybe (tr lang "none") T.pack session
    , tr lang "  Current model: " <> model
    ]

executeCommand lang _ _ _ ShowSettings = runSettingsCommand lang ""

executeCommand lang bridge _ _ Providers = do
  result <- listProviders bridge
  return $ Just $ case result of
    Right [] -> tr lang "No providers configured (see ~/.trha/providers.json)."
    Right ps -> (tr lang "Providers:" <> "\n") <> T.unlines
      [ "  - " <> piName p <> " (" <> piKind p <> ")"
          <> " · " <> piDefault p
          <> (if piInUse p then " · in use" else "")
      | p <- ps ]
      <> tr lang "Switch providers in the TUI (/provider or ctrl+x p)."
    Left err -> tr lang "Error: " <> T.pack (show err)

executeCommand lang _ _ _ (SetSetting "" _) =
  return $ Just (tr lang "Usage: /settings <key> <value>")

executeCommand lang _ _ _ (SetSetting key raw)
  | T.null key || T.null (T.strip raw) =
      return $ Just (tr lang "Usage: /settings <key> <value>")
  | otherwise = runSettingsCommand lang (key <> " " <> raw)

executeCommand lang bridge _ _ Plugins = do
  result <- listPlugins bridge
  return $ Just $ case result of
    Right [] -> tr lang "No plugins registered."
    Right ps -> (tr lang "Plugins:" <> "\n") <> T.unlines
      [ "  - " <> pluginName p <> " " <> pluginVersion p
          <> maybe "" (\d -> "  —  " <> d) (Just (pluginDescription p))
      | p <- ps ]
    Left err -> tr lang "Error: " <> T.pack (show err)

executeCommand lang _ _ _ (Unknown cmd) =
  return $ Just $ tr lang "Unknown command: " <> cmd <> tr lang " — try /help"

-- | Submit a plan. One line goes through the single-command gate; two or more
-- (separated by @;@ or newlines) become a stepwise plan in the kernel, decided
-- one step at a time.
executeCommand lang bridge sessionRef _ (Plan planText) = do
  if T.null (T.strip planText)
    then return $ Just (tr lang "Usage: /plan <what to do>")
    else do
      session <- readIORef sessionRef
      case session of
        Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
        Just sid -> do
          recordUser sid planText
          let steps = splitPlanSteps planText
          if length steps >= 2
            then do
              result <- submitPlan bridge sid steps
              return $ Just $ case result of
                Right pv -> T.unlines
                  [ tr lang "Plan submitted — decide each step with /approve, /skip, /reject or /abandon."
                  , renderPlanBrief pv ]
                Left err -> tr lang "Error: " <> T.pack (show err)
            else do
              result <- planStep bridge sid planText
              return $ Just $ case result of
                Right (PlanAwaiting preview) ->
                  T.unlines [ tr lang "⏸ Plan submitted — awaiting your decision (/approve or /deny)."
                            , tr lang "Plan: " <> preview ]
                Left err -> tr lang "Error: " <> T.pack (show err)

-- | Skip / reject the pending step, or drop the whole plan.
executeCommand lang bridge sessionRef _ SkipStep = decidePlanStep lang bridge sessionRef "skip"
executeCommand lang bridge sessionRef _ RejectStep = decidePlanStep lang bridge sessionRef "reject"
executeCommand lang bridge sessionRef _ AbandonPlan = decidePlanStep lang bridge sessionRef "abandon"

-- | Approve. If a multi-step plan is active in the kernel, approve its pending
-- step, run it as a normal agent turn, then report the result; otherwise the
-- single-command gate answers.
executeCommand lang bridge sessionRef _ Approve = do
  session <- readIORef sessionRef
  case session of
    Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
    Just sid -> do
      mplan <- fetchPlan bridge sid
      case mplan of
        Right pv | pvPhase pv == "planning" -> approvePlanStep lang bridge sid
        _ -> do
          result <- approvePlan bridge sid
          case result of
            Right (PlanApproved reply) -> do
              recordChunk sid (Right (ChunkDelta reply))
              return $ Just reply
            Right PlanDenied -> return $ Just (tr lang "Plan was not approved.")
            Left err -> return $ Just $ tr lang "Error: " <> T.pack (show err)

-- | Deny: on a plan that means rejecting the pending step.
executeCommand lang bridge sessionRef _ Deny = do
  session <- readIORef sessionRef
  case session of
    Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
    Just sid -> do
      mplan <- fetchPlan bridge sid
      case mplan of
        Right pv | pvPhase pv == "planning" -> decidePlanStep lang bridge sessionRef "reject"
        _ -> do
          result <- denyPlan bridge sid
          return $ Just $ case result of
            Right PlanDenied -> tr lang "Plan denied."
            Right (PlanApproved _) -> tr lang "Plan was approved (unexpected)."
            Left err -> tr lang "Error: " <> T.pack (show err)

-- | List local sessions (from ~/.trha transcript index).
executeCommand lang _ _ _ ResumeList = do
  sessions <- listLocalSessions
  return $ Just $ if null sessions
    then tr lang "No local sessions found. Run a conversation first (transcripts are stored under ~/.trha/sessions)."
    else (tr lang "Local sessions:" <> "\n") <> T.unlines
      [ "  [" <> T.pack (show (i :: Int)) <> "] " <> ssTitle s
          <> "  (" <> T.pack (ssId s)
          <> maybe "" (\m -> " · " <> m) (ssModel s)
          <> " · " <> T.pack (show (ssTurns s)) <> tr lang " turn(s)"
          <> maybe "" (\ts -> " · " <> ts) (ssLastTs s)
          <> ")"
      | (i, s) <- zip [1 :: Int ..] sessions ]

-- | Resume a local session by list number or id: replay its transcript
-- and set it as the active session (continuing works while the
-- orchestration layer still holds it).
executeCommand lang _ sessionRef _ (ResumeSelect sel) = do
  sessions <- listLocalSessions
  case pickLocalSession sel sessions of
    Nothing -> return $ Just $ tr lang "No local session matches: " <> T.pack sel
    Just s -> do
      events <- loadTranscript (ssId s)
      let replay = renderReplayText (renderReplay events)
      writeIORef sessionRef (Just (ssId s))
      return $ Just $
        (if T.null replay
           then tr lang "Resumed " <> T.pack (ssId s) <> tr lang " (empty transcript)"
           else tr lang "Resumed " <> T.pack (ssId s) <> ":\n" <> replay)
        <> "\n" <> tr lang "Note: continuing needs the session on the orchestration side."

executeCommand lang bridge sessionRef modelRef (SendMessage msg) = do
  session <- readIORef sessionRef
  case session of
    Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
    Just sid -> do
      recordUser sid msg
      model <- readIORef modelRef
      recordModelRequest sid model
      toolRef <- newIORef ([] :: [ToolEvent])
      cancel <- subscribeSessionEvents bridge sid $ \ev -> case ev of
        Right tev -> do
          recordToolEvent sid tev
          modifyIORef' toolRef (tev :)
        Left _ -> return ()
      result <- sendMessage bridge sid msg
      threadDelay 100000 -- drain trailing tool events before tearing down
      cancel
      recordChunk sid result
      tools <- readIORef toolRef
      let toolLines = T.unlines
            [ T.unlines (toolCardWithStatus (T.pack (teName ev)) (teArgs ev)
                           (toCardStatus (teStatus ev)) (teDurationMs ev))
            | ev <- reverse tools
            , teStatus ev /= ToolRunRunning
            ]
      return $ Just $ case result of
        Right chunk -> toolLines <> case chunk of
          ChunkDelta text -> text
          ChunkToolCall name args -> "[Tool call: " <> T.pack name <> " " <> T.unwords args <> "]"
          ChunkDone usage -> "[Done: " <> T.pack (show (usageTotalTokens usage)) <> " tokens]"
        Left err -> toolLines <> tr lang "Error: " <> T.pack (show err)

-- | Map the wire tool status to the card status type.
toCardStatus :: ToolRunStatus -> ToolStatus
toCardStatus s = case s of
  ToolRunRunning   -> ToolRunning
  ToolRunSucceeded -> ToolSucceeded
  ToolRunFailed e  -> ToolFailed e

-- | One plan decision, rendered as a compact list.
decidePlanStep :: Lang -> SchedulerBridge -> IORef (Maybe SessionId) -> Text -> IO (Maybe Text)
decidePlanStep lang bridge sessionRef action = do
  session <- readIORef sessionRef
  case session of
    Nothing -> return $ Just (tr lang "No active session. Use /new to create one.")
    Just sid -> do
      result <- decideStep bridge sid action
      return $ Just $ case result of
        Right pv -> renderPlanBrief pv
        Left err -> tr lang "Error: " <> T.pack (show err)

-- | Release the pending plan step, run it, and report back — the same shape the
-- TUI and Desktop use, so all three shells tell the kernel the truth.
approvePlanStep :: Lang -> SchedulerBridge -> SessionId -> IO (Maybe Text)
approvePlanStep lang bridge sid = do
  approved <- decideStep bridge sid "approve"
  case approved of
    Left err -> return $ Just $ tr lang "Error: " <> T.pack (show err)
    Right pv -> case planStepOut pv of
      Nothing -> return $ Just (renderPlanBrief pv)
      Just step -> do
        ran <- sendMessage bridge sid (psvTitle step)
        let ok = either (const False) (const True) ran
            reply = either (const "") chunkText ran
        recorded <- reportStep bridge sid (psvId step) ok
        case recorded of
          Left err -> return $ Just $ tr lang "Error: " <> T.pack (show err)
          Right pv' -> do
            recordChunk sid (Right (ChunkDelta reply))
            return $ Just (reply <> "\n" <> renderPlanBrief pv')
  where
    chunkText (ChunkDelta t) = t
    chunkText _              = ""
