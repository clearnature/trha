{-# LANGUAGE OverloadedStrings #-}

-- | 发消息的主流程：建会话、订阅 SSE、发送、收尾。
--
-- 从 @UI.Brick@ 拆出的最大一块交互逻辑（84 行）。它是事件流的汇聚点：
-- 用户输入一份文本，这里负责把它变成一次完整的回合，并在失败时给出可恢复的路径。
module UI.Brick.Chat
  ( handleChatWith
  ) where

import Brick (EventM, get, modify)
import Brick.BChan (writeBChan)
import Control.Concurrent.Async (async)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import System.Timeout (timeout)

import Bridge.Scheduler
  ( SchedulerBridge, createSession, sendMessageWithTargetEffort
  , subscribeSessionEventsWithTerminal )
import Config.Settings (resolveConfig)
import Core.Bootstrap (ensureBackend)
import Core.Types
  ( CLIError(..), SessionMode(..), StreamChunk(..), configEffort
  , defaultCLIConfig, effectiveReasoningLanguage, mkUsage )
import Core.Transcript (recordChunk, recordSession, recordToolEvent, recordUser)
import UI.Brick.DialogKeys (scrollBottom)
import UI.Brick.MessageOps (appendMsg, now, setWindowTitle)
import UI.Brick.SessionView (refreshSidebar)
import UI.Event (AppEvent(..))
import UI.I18n (tr)
import UI.State (AppState(..), ResourceName(..), mkMsg)

-- | 发送一条消息：懒建会话、异步发送、绝不阻塞 UI。
--
-- 回合进行中，工具生命周期事件通过 SSE 到达；它们既写进 transcript，
-- 也通过 'EvTool' 展示到界面。回复正文以 step 的返回值（而非流）为准，
-- 所以流断了也不会把回合卡在 busy 状态。
handleChatWith :: Text -> Text -> EventM ResourceName AppState ()
handleChatWith display sendText = do
  t <- liftIO now
  t0 <- liftIO getCurrentTime
  appendMsg (mkMsg "user" display t)
  modify $ \st -> st { appBusy = True, appStatus = tr (appLang st) "Thinking..."
                     , appTurnStart = Just t0 }
  st <- get
  case appSessionId st of
    Just sid -> liftIO $ setWindowTitle ("● trha · " <> T.take 8 (T.pack sid))
    Nothing  -> return ()

  st <- get
  let bridge = appBridge st
      chan   = appChan st
      model  = appModel st
      provider = appProvider st
      runStepWithTools sid = do
        doneVar <- liftIO newEmptyMVar
        cancel <- subscribeSessionEventsWithTerminal bridge sid (toolSink chan sid)
                    (\t' -> writeBChan chan (EvResponse (Right (ChunkDelta t'))))
                    (void (tryPutMVar doneVar ()))
                    (writeBChan chan . EvNotice)
        cfg <- liftIO (resolveConfig defaultCLIConfig)
        let eff = if T.toLower (configEffort cfg) == "auto"
                    then Nothing else Just (configEffort cfg)
            mlang = effectiveReasoningLanguage cfg
        result <- sendMessageWithTargetEffort bridge sid provider (Just model) eff mlang sendText
        -- Give the stream a bounded moment to deliver trailing tool events,
        -- then stop it.  The reply itself is already in hand.
        _ <- liftIO $ timeout 250000 (takeMVar doneVar)
        liftIO cancel
        case result of
          Right (c, musage) -> do
            recordChunk sid (Right c)
            case c of
              ChunkDelta reply -> writeBChan chan (EvFinalReply reply)
              _                -> return ()
            -- Always finalize: a missing usage echo must not leave the
            -- spinner running.
            writeBChan chan (EvResponse (Right (ChunkDone (fromMaybe zero musage))))
          Left err -> do
            -- 调度层崩了会让长任务直接断掉：这里尝试拉起一次。会话与
            -- 历史由 scheduler 从 stateDir 恢复，用户重发即可继续。
            case err of
              ConnectionError _ -> do
                started <- ensureBackend (appEffCfg st)
                writeBChan chan . EvResponse . Left $
                  if null started
                    then err
                    else ServerError (tr (appLang st)
                           "The scheduler stopped and has been restarted; resend to continue.")
              _ -> writeBChan chan (EvResponse (Left err))
        refreshSidebar bridge chan sid
      zero = mkUsage 0 0 0
  void $ liftIO $ async $ case appSessionId st of
    Just sid -> do
      recordUser sid display
      runStepWithTools sid
    Nothing -> do
      -- 首次发消息自动建会话时，同样要把当前姿态带上：否则服务端按缺省
      -- read-only 建会话，界面显示 YOLO 但工具仍被拒。
      sessResult <- createSession bridge (smMode <$> appMode st)
      writeBChan chan (EvSession sessResult)
      case sessResult of
        Right sid -> do
          recordSession sid model
          recordUser sid display
          runStepWithTools sid
        Left _ ->
          return ()
  scrollBottom
  where
    -- Record every tool event; completed/failed ones also go to the UI.
    toolSink chan sid ev = case ev of
      Right toolEv -> do
        recordToolEvent sid toolEv
        writeBChan chan (EvTool (Right toolEv))
      Left err -> writeBChan chan (EvTool (Left err))
