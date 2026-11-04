{-# LANGUAGE OverloadedStrings #-}

-- | 对话框的通用操作：查询字符的追加/删除、对栈顶对话框施加纯变换。
--
-- 从 @UI.Brick@ 的交互层拆出。这些操作不关心对话框是哪一种，只判断它是否
-- 「可过滤」，因此是 @handleDialogKey@ 与 @dialogActivate@ 的共同底座。
module UI.Brick.DialogKeys
  ( dialogAppend
  , dialogDelete
  , withCommands
  , modifyTop
  , scrollBottom
  , persistSelection
  , chooseProvider
  , selectSkill
  ) where

import Brick (EventM, get, gets, modify, viewportScroll, vScrollToEnd)
import Brick.Widgets.Edit (editorText)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)

import Config.Settings (saveConfig)
import Core.Types (CLIConfig(..), ProviderInfo(..), modelForProvider)

import UI.Dialog
  ( Dialog(..), dialogCommandsAppend, dialogCommandsDelete, dialogModelsAppend
  , dialogModelsDelete, dialogSessionsAppend, dialogSessionsDelete
  , dialogSkillsAppend, dialogSkillsDelete, stackPop, stackPush, stackTop )
import UI.I18n (tr)
import UI.State (AppState(..), ResourceName(..))

-- | 往当前对话框的查询行追加一个字符（只有可过滤的列表才响应）。
dialogAppend :: Char -> Dialog -> Dialog
dialogAppend c d = case d of
  DialogCommands{} -> dialogCommandsAppend c d
  DialogSkills{}   -> dialogSkillsAppend c d
  DialogModels{}   -> dialogModelsAppend c d
  DialogSessions{} -> dialogSessionsAppend c d
  _                -> d

-- | 删除查询行的最后一个字符。
dialogDelete :: Dialog -> Dialog
dialogDelete d = case d of
  DialogCommands{} -> dialogCommandsDelete d
  DialogSkills{}   -> dialogSkillsDelete d
  DialogModels{}   -> dialogModelsDelete d
  DialogSessions{} -> dialogSessionsDelete d
  _                -> d

-- | 仅当栈顶是可过滤的列表时才施加变换。
withCommands :: (Dialog -> Dialog) -> EventM ResourceName AppState ()
withCommands f = do
  st <- get
  case stackTop (appDialogs st) of
    Just DialogCommands{} -> modifyTop f
    Just DialogSkills{}   -> modifyTop f
    -- 模型/会话列表也可过滤：字符输入进查询行，而不是被丢掉。
    Just DialogModels{}   -> modifyTop f
    Just DialogSessions{} -> modifyTop f
    _                     -> return ()

-- | 对对话框栈顶施加一个纯变换（弹出 → 变换 → 压回）。
modifyTop :: (Dialog -> Dialog) -> EventM ResourceName AppState ()
modifyTop f = modify $ \s -> s { appDialogs =
  case stackTop (appDialogs s) of
    Just d  -> stackPush (f d) (stackPop (appDialogs s))
    Nothing -> appDialogs s }

-- | 把消息区滚到底部（对话框选完后回到最新消息）。
scrollBottom :: EventM ResourceName AppState ()
scrollBottom = vScrollToEnd (viewportScroll MessageArea)

-- | 记住所选供应商与模型（写回 settings.yaml）。
persistSelection :: Text -> Text -> EventM ResourceName AppState ()
persistSelection providerName model = do
  st <- get
  let cfg = (appEffCfg st) { configProvider = providerName, configModel = model }
  liftIO $ saveConfig cfg
  modify $ \s -> s { appEffCfg = cfg }

-- | 选定供应商：记住它，并保证当前模型属于该供应商。
--
-- 若当前模型不在新供应商的清单里（换到别家），回落到该供应商的默认模型；
-- 否则保持用户已有的模型选择不变。
chooseProvider :: ProviderInfo -> EventM ResourceName AppState ()
chooseProvider p = do
  lang <- gets appLang
  modify $ \s ->
    let model = modelForProvider p (appModel s)
    in s { appProvider = Just (piName p)
         , appModel = model
         , appStatus = tr lang "Provider: " <> piName p <> " · " <> model }
  st2 <- get
  persistSelection (piName p) (appModel st2)
  scrollBottom

-- | 选中一个技能：把它填进输入框作为 @/skill:<name> @，并关掉面板。
selectSkill :: Text -> EventM ResourceName AppState ()
selectSkill name =
  modify $ \s -> s { appInput = editorText InputArea (Just 1) ("/skill:" <> name <> " ")
                   , appPalette = Nothing }
