{-# LANGUAGE OverloadedStrings #-}

-- | 临时提示条（toast）：设一条消息，三秒后自动过期。
--
-- 从 @UI.Brick@ 的交互层拆出。它被主题/语言切换、命令回执等处共用，是
-- @applyTheme@ / @applyLanguage@ / @dialogActivate@ 的共同底座。
module UI.Brick.Toast
  ( showToast
  ) where

import Brick (EventM, get, modify)
import Brick.BChan (writeBChan)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)

import UI.Event (AppEvent(..))
import UI.State (AppState(..), ResourceName(..))

-- | 显示一条提示，并在三秒后向事件通道投递过期事件把提示条收掉。
--
-- 计时不占用 UI 线程：@async@ 里只有一次 @threadDelay@ 加一次入队，
-- 真正的重绘由 'EvToastExpire' 事件驱动。
showToast :: Text -> EventM ResourceName AppState ()
showToast msg = do
  t <- liftIO getCurrentTime
  st <- get
  modify $ \s -> s { appToast = Just (msg, t) }
  void $ liftIO $ async $ do
    threadDelay 3000000
    writeBChan (appChan st) (EvToastExpire t)
