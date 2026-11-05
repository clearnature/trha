{-# LANGUAGE OverloadedStrings #-}

-- | 四类列表对话框的编辑操作：查询串增删、条目读取、选中项移动。
--
-- models / sessions / skills / commands 各 4-6 个，共 18 个函数。
-- 它们都是纯函数（Dialog -> Dialog 或 Dialog -> 列表），不碰 EventM。
module UI.Dialog.Editing
  ( dialogModelsAppend, dialogModelsDelete, dialogModelsQuery, dialogModelsItems
  , dialogSessionsAppend, dialogSessionsDelete, dialogSessionsQuery, dialogSessionsItems
  , dialogSkillsAppend, dialogSkillsDelete, dialogSkillsQuery, dialogSkillsItems
  , dialogCommandsAppend, dialogCommandsDelete, dialogCommandsQuery
  , dialogCommandsSelected, dialogCommandsItems, dialogCommandsInitialSel
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Core.SessionSummary (SessionSummary)
import Core.Types (ModelInfo)
import UI.Render.Picker
  ( PickerItem, filterItems, firstSelectable, queryAppend, queryDelete )
import UI.Skills (Skill)

import UI.Dialog.Selection (filterModels, filterSessions, filterSkills)
import UI.Dialog.Types (Dialog(..))

dialogModelsAppend :: Char -> Dialog -> Dialog
dialogModelsAppend c (DialogModels ms q _) = DialogModels ms (queryAppend q c) 0

dialogModelsDelete :: Dialog -> Dialog
dialogModelsDelete (DialogModels ms q _) = DialogModels ms (queryDelete q) 0

dialogModelsQuery :: Dialog -> Text
dialogModelsQuery (DialogModels _ q _) = q

-- | 过滤后的模型列表（选中索引指向它）。

dialogModelsItems :: Dialog -> [ModelInfo]
dialogModelsItems (DialogModels ms q _) = filterModels q ms

dialogSessionsAppend :: Char -> Dialog -> Dialog
dialogSessionsAppend c (DialogSessions ss q _) = DialogSessions ss (queryAppend q c) 0

dialogSessionsDelete :: Dialog -> Dialog
dialogSessionsDelete (DialogSessions ss q _) = DialogSessions ss (queryDelete q) 0

dialogSessionsQuery :: Dialog -> Text
dialogSessionsQuery (DialogSessions _ q _) = q

dialogSessionsItems :: Dialog -> [SessionSummary]
dialogSessionsItems (DialogSessions ss q _) = filterSessions q ss

dialogSkillsAppend :: Char -> Dialog -> Dialog
dialogSkillsAppend c (DialogSkills ss q _) = DialogSkills ss (queryAppend q c) 0

dialogSkillsDelete :: Dialog -> Dialog
dialogSkillsDelete (DialogSkills ss q _) = DialogSkills ss (queryDelete q) 0

dialogSkillsQuery :: Dialog -> Text
dialogSkillsQuery (DialogSkills _ q _) = q

dialogSkillsItems :: Dialog -> [Skill]
dialogSkillsItems (DialogSkills ss q _) = filterSkills q ss

dialogCommandsAppend :: Char -> Dialog -> Dialog
dialogCommandsAppend c (DialogCommands all0 q _) =
  let q' = queryAppend q c
  in DialogCommands all0 q' 0

-- | Backspace one query character; the seed @/@ is never eaten (a
-- one-character query is left untouched, so the menu can't empty out).

dialogCommandsDelete :: Dialog -> Dialog
dialogCommandsDelete (DialogCommands all0 q _)
  | T.length q <= 1 = DialogCommands all0 q 0
  | otherwise       = DialogCommands all0 (queryDelete q) 0

dialogCommandsQuery :: Dialog -> Text
dialogCommandsQuery (DialogCommands _ q _) = q

dialogCommandsSelected :: Dialog -> Int
dialogCommandsSelected (DialogCommands _ _ s) = s

-- | The filtered items of the command dialog.

dialogCommandsItems :: Dialog -> [PickerItem]
dialogCommandsItems (DialogCommands all0 q _) = filterItems q all0

-- | 打开命令面板时该停在哪一项：过滤后列表的第一个可选条目。
--
-- 必须基于过滤后的列表计算。'dialogCommandsItems' 每次都用 query 重新过滤，
-- 若按全量列表算索引，过滤到只剩一项时它会越界，回车落到空分支，
-- 表现为「输入 /about 回车毫无反应」。

dialogCommandsInitialSel :: [PickerItem] -> Text -> Int
dialogCommandsInitialSel all0 q = firstSelectable (filterItems q all0)
