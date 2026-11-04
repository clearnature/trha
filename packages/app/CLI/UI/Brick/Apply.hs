{-# LANGUAGE OverloadedStrings #-}

-- | 应用全局设置的运行时切换：语言与主题。
--
-- 从 @UI.Brick@ 的交互层拆出。两者形态一致——改 'AppState'、写回
-- @settings.yaml@、给一条 toast 回执——是 @dialogActivate@ 选定语言/主题后的落点。
module UI.Brick.Apply
  ( applyLanguage
  , applyTheme
  , openSettingsPanel
  , modeAction
  ) where

import Brick (EventM, get, modify)
import Brick.BChan (writeBChan)
import Control.Concurrent.Async (async)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Data.Text (Text)
import qualified Data.Text as T

import Bridge.Scheduler (applySessionMode)
import Config.Settings (resolveConfig, saveConfig)
import Core.Types (CLIConfig(..), SessionMode(..), defaultCLIConfig)
import UI.Brick.DialogKeys (scrollBottom)
import UI.Brick.Toast (showToast)
import UI.Dialog (stackPop)
import UI.Event (AppEvent(..))
import UI.I18n (Lang, langName, tr)
import UI.State
  ( AppState(..), ResourceName(..), SettingsFocus(..), SettingsPanel(..)
  , SettingsTab(..) )
import UI.StatusInfo (collectStatusInfo)
import UI.Theme (resolveTheme, themeName)

-- | 切换语言：持久化到配置、关掉对话框、状态栏留一句回执。
applyLanguage :: Lang -> EventM ResourceName AppState ()
applyLanguage l = do
  st <- get
  let cfg' = (appEffCfg st) { configLang = langName l }
  liftIO $ saveConfig cfg'
  modify $ \s -> s { appLang = l, appEffCfg = cfg'
                   , appDialogs = stackPop (appDialogs s)
                   , appStatus = tr l "Language: " <> langName l }

-- | 切换主题：认不出的名字只给提示，不改配置也不改当前主题。
applyTheme :: Text -> EventM ResourceName AppState ()
applyTheme name = do
  st2 <- get
  let th = resolveTheme name
  if T.toLower (themeName th) /= T.toLower name
    then showToast ("Unknown theme: " <> name)
    else do
      let cfg' = (appEffCfg st2) { configTheme = themeName th }
      liftIO $ saveConfig cfg'
      modify $ \s -> s { appTheme = th, appEffCfg = cfg' }
      showToast ("Theme: " <> themeName th)

-- | 打开 @/settings@ 面板：先把有效配置快照下来，并异步拉取状态行。
openSettingsPanel :: EventM ResourceName AppState ()
openSettingsPanel = do
  st <- get
  let chan = appChan st
      model = appModel st
      mSid = appSessionId st
  cfg <- liftIO (resolveConfig defaultCLIConfig)
  _ <- liftIO $ async $ do
    rows <- collectStatusInfo cfg mSid model
    writeBChan chan (EvStatusInfo rows)
  modify $ \s -> s { appSettings = Just (SettingsPanel TabSettings FocusList 0 "" Nothing Nothing)
                    , appEffCfg = cfg }

-- | 切换权限姿态（read-only → ask → auto → yolo → plan，循环）。
--
-- 没有会话时只在本地循环标签，让快捷键仍有响应；有会话时把动作发给调度层，
-- 由 EvMode 回来更新状态。@plan@ 是标志位而非独立模式——scheduler 侧只有
-- read-only/ask/auto/yolo 四档，切到 plan 时审批模式仍是 ask。
modeAction :: Value -> EventM ResourceName AppState ()
modeAction body = do
  st <- get
  case appSessionId st of
    Nothing -> do
      let cur = maybe "read-only" smMode (appMode st)
          nextOf m = case m of
            "read-only" -> "ask"
            "ask"       -> "auto"
            "auto"      -> "yolo"
            "yolo"      -> "plan"
            _           -> "read-only"
          nxt = nextOf cur
          mode' = if nxt == "plan" then "ask" else nxt
          label = case nxt of
            "read-only" -> "Read only"
            "ask"       -> "Ask"
            "auto"      -> "Auto"
            "yolo"      -> "YOLO"
            _           -> "Plan"
      modify $ \s -> s
        { appMode = Just (SessionMode mode' label (nxt == "plan") Nothing)
        , appStatus = tr (appLang s) "Mode switched" }
    Just sid -> do
      let bridge = appBridge st
          chan = appChan st
      void $ liftIO $ async $ applySessionMode bridge sid body >>= writeBChan chan . EvMode
  scrollBottom
