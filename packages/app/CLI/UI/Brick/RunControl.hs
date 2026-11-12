{-# LANGUAGE OverloadedStrings #-}

-- | 运行控制：中断、停服务、审批决定、Escape 层级。
--
-- 从 @UI.Brick@ 的交互层拆出。共同点是「对正在跑的回合施加控制」——
-- 要么打断它，要么停掉整个后端，要么回答它挂起时的审批询问。
module UI.Brick.RunControl
  ( requestInterrupt
  , requestStopServices
  , stopServicesAndHalt
  , decideApprovalNow
  , escapeHierarchy
  , escapeWithoutApproval
  , runShellCommand
  , approveAndRun
  ) where

import Brick (EventM, get, gets, halt, modify)
import Brick.BChan (writeBChan)
import Control.Concurrent.Async (async)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)

import Bridge.Scheduler
  ( SchedulerBridge, decidePlan, decideStep, interruptSession, reportStep
  , sendMessage )
import Core.RunState (stopAll, stopResultText)
import Core.Types
  ( CLIError, PlanStepView(..), PlanView, SessionId, StreamChunk(..)
  , planStepOut )
import System.Exit (ExitCode(..))
import UI.Brick.DialogKeys (scrollBottom)
import UI.Brick.MessageOps (appendMsg, now)
import UI.Commands (runLocalShell)
import UI.Event (AppEvent(..))
import UI.Dialog
  ( Dialog(..), EscFlags(..), EscOutcome(..), escWiring, resolveEscape
  , stackNull, stackPop, stackPush )
import UI.Event (AppEvent(..))
import UI.I18n (tr)
import UI.State (AppState(..), ChatMessage(..), ResourceName(..), mkMsg)

-- | Ask the host to stop the running turn.
requestInterrupt :: EventM ResourceName AppState ()
requestInterrupt = do
  st <- get
  modify $ \s -> s { appStatus = tr (appLang s) "Interrupting..." }
  case appSessionId st of
    Nothing -> return ()
    Just sid -> void $ liftIO $ async $ void (interruptSession (appBridge st) sid)

-- | Ctrl+Alt+Q: the service-level stop.  The kernel and scheduler are shared
-- by every shell, so this needs the same explicit confirmation as @/stop@ —
-- one keystroke must never tear down the backend.  The dialog defaults to
-- "No"; confirming runs 'stopAll' and then leaves the shell.
requestStopServices :: EventM ResourceName AppState ()
requestStopServices = do
  lang <- gets appLang
  modify $ \s -> s
    { appDialogs = stackPush
        (DialogConfirm (tr lang "Stop the kernel and scheduler? Every shell (TUI, Desktop, Web) disconnects.") 1)
        (appDialogs s)
    , appPendingStop = True }

-- | Confirmed service stop: SIGTERM kernel + scheduler, report, then halt.
-- The dialog itself was already popped by 'dialogActivate'.
stopServicesAndHalt :: EventM ResourceName AppState ()
stopServicesAndHalt = do
  modify $ \s -> s { appPendingStop = False
                   , appStatus = tr (appLang s) "Stopping services..." }
  t <- liftIO now
  rs <- liftIO (stopAll False)
  let out = T.intercalate "\n"
              [ T.pack (stopResultText svc r) | (svc, r) <- rs ]
  appendMsg (mkMsg "system" out t)
  halt

-- | Answer the parked ask: post the decision and let EvVerdict close the
-- loop (it clears appApproval and busy).
decideApprovalNow :: Bool -> EventM ResourceName AppState ()
decideApprovalNow approve = do
  st <- get
  modify $ \s -> s { appDialogs = stackPop (appDialogs s)
                   , appStatus = tr (appLang s)
                       (if approve then "Approving..." else "Denying...") }
  case appSessionId st of
    Nothing -> do
      -- nothing to answer: drop the parked state instead of hanging
      modify $ \s -> s { appApproval = Nothing, appBusy = False
                       , appStatus = tr (appLang s) "No session to approve" }
    Just sid -> do
      let bridge = appBridge st
          chan   = appChan st
      void $ liftIO $ async $ do
        r <- decidePlan bridge sid approve
        writeBChan chan (EvVerdict r)

-- | Escape resolution per MiMo's hierarchy.  A parked ask is rejected on
-- escape (permission page escapeKey=reject); otherwise pop an open
-- dialog; a second press within 5 seconds requests an interrupt (the
-- real cancel lands with the approval lock in M3).
escapeHierarchy :: EventM ResourceName AppState ()
escapeHierarchy = do
  approval <- gets appApproval
  case approval of
    Just _  -> decideApprovalNow False
    Nothing -> escapeWithoutApproval

escapeWithoutApproval :: EventM ResourceName AppState ()
escapeWithoutApproval = do
  st <- get
  now <- liftIO getCurrentTime
  let within = maybe False (\t0 -> diffUTCTime now t0 <= 5) (appEscLast st)
      -- Only a turn that is actually running can be interrupted; an idle
      -- press leaves no arm behind (otherwise the next press would fire).
      running = appBusy st && isNothing (appApproval st)
      (fired, keepArmed) = escWiring running within (isJust (appEscLast st))
      arm = if keepArmed then Just now else Nothing
      flags = EscFlags { efSelection = False
                       , efStack = not (stackNull (appDialogs st))
                       , efShell = False
                       , efComplete = isJust (appComp st) }
  case resolveEscape flags of
    EscPopDialog ->
      modify $ \s -> s { appDialogs = stackPop (appDialogs s), appEscLast = Nothing
                       , appPendingStop = False }
    _ | fired -> do
          modify $ \s -> s { appEscLast = Nothing }
          requestInterrupt
      | otherwise -> modify $ \s -> s { appEscLast = arm }

-- | @!cmd@ / @/shell cmd@：跑一条本地 shell 命令，把输出贴回消息区。
--
-- 输出按 20000 字符截断（避免一次刷爆消息区），非零退出码补一行 @(exit N)@。
runShellCommand :: Text -> EventM ResourceName AppState ()
runShellCommand cmd = do
  t <- liftIO now
  appendMsg (mkMsg "shell" ("$ " <> cmd) t)
  r <- liftIO (runLocalShell cmd)
  case r of
    Left e -> appendMsg (mkMsg "error" e t)
    Right (code, out, err) -> do
      let body = T.take 20000 (T.pack (out <> err))
          suffix = case code of
            ExitSuccess -> ""
            ExitFailure n -> "\n(exit " <> T.pack (show n) <> ")"
      appendMsg (mkMsg "shell" (body <> suffix) t)
  scrollBottom

-- | 放行计划的一个步骤：decide → 执行 → 回报，把新状态与回复一起交回。
--
-- 三级都可能是 Left（内核拒绝 / 发送失败 / 回报失败），逐层短路；
-- 「没有下一步」是正常终止，返回 @Right (pv, Nothing)@。
approveAndRun :: SchedulerBridge -> SessionId -> IO (Either CLIError (PlanView, Maybe Text))
approveAndRun bridge sid = do
  approved <- decideStep bridge sid "approve"
  case approved of
    Left e -> pure (Left e)
    Right pv -> case planStepOut pv of
      Nothing -> pure (Right (pv, Nothing))
      Just step -> do
        ran <- sendMessage bridge sid (psvTitle step)
        let ok = either (const False) (const True) ran
            reply = either (const Nothing) (Just . chunkText) ran
        reported <- reportStep bridge sid (psvId step) ok
        pure $ case reported of
          Left e    -> Left e
          Right pv' -> Right (pv', reply)
  where
    chunkText (ChunkDelta t) = t
    chunkText _              = ""
