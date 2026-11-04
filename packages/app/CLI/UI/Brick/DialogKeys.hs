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
  ) where

import Brick (EventM, get, modify)

import UI.Dialog
  ( Dialog(..), dialogCommandsAppend, dialogCommandsDelete, dialogModelsAppend
  , dialogModelsDelete, dialogSessionsAppend, dialogSessionsDelete
  , dialogSkillsAppend, dialogSkillsDelete, stackPop, stackPush, stackTop )
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
