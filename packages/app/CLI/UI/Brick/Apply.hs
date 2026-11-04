{-# LANGUAGE OverloadedStrings #-}

-- | 应用全局设置的运行时切换：语言与主题。
--
-- 从 @UI.Brick@ 的交互层拆出。两者形态一致——改 'AppState'、写回
-- @settings.yaml@、给一条 toast 回执——是 @dialogActivate@ 选定语言/主题后的落点。
module UI.Brick.Apply
  ( applyLanguage
  , applyTheme
  ) where

import Brick (EventM, get, modify)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import qualified Data.Text as T

import Config.Settings (saveConfig)
import Core.Types (CLIConfig(..))
import UI.Brick.Toast (showToast)
import UI.Dialog (stackPop)
import UI.I18n (Lang, langName, tr)
import UI.State (AppState(..), ResourceName(..))
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
