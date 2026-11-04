{-# LANGUAGE OverloadedStrings #-}

-- | 应用全局设置的运行时切换：语言与主题。
--
-- 从 @UI.Brick@ 的交互层拆出。两者形态一致——改 'AppState'、写回
-- @settings.yaml@、给一条 toast 回执——是 @dialogActivate@ 选定语言/主题后的落点。
module UI.Brick.Apply
  ( applyLanguage
  , applyTheme
  , openSettingsPanel
  ) where

import Brick (EventM, get, modify)
import Brick.BChan (writeBChan)
import Control.Concurrent.Async (async)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import qualified Data.Text as T

import Config.Settings (resolveConfig, saveConfig)
import Core.Types (CLIConfig(..), defaultCLIConfig)
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
