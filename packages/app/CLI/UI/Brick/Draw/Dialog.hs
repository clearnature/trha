{-# LANGUAGE OverloadedStrings #-}

-- | 命令面板与供应商向导的渲染。
--
-- 从 @UI.Brick@ 拆出的批次 2b（对话框家族的轻量成员）。这里只做 Widget 装配：
-- 条目筛选与滚动窗口来自 UI.Render.Picker，向导字段来自 UI.State。
--
-- @drawDialog@（310 行、十余种 'Dialog' 构造子）与 @drawSettingsPanel@ 留待
-- 批次 2c——它们体量大，需要单独一轮。
module UI.Brick.Draw.Dialog
  ( drawPalette
  , drawWizard
  , wizardSummary
  ) where

import Brick
  ( Widget, attrName, hBox, hLimit, padLeftRight, str, vBox, withAttr )
import Brick.Widgets.Border (borderWithLabel)
import Data.Text (Text)
import qualified Data.Text as T

import UI.Dialog (Dialog, dialogCommandsItems, dialogCommandsSelected)
import UI.Render.Picker (PickerItem(..), isSection, windowRange)
import UI.State (ProviderWizard(..), ResourceName(..), wizardPrompts)
import UI.TextWidth (takeCells)

-- | 命令面板：输入 @/@ 后就地展开的列表（MiMo 形态：在提示上方，随输入
-- 过滤，不是抢焦点的居中弹窗）。
drawPalette :: Dialog -> Widget ResourceName
drawPalette d =
  withAttr (attrName "tool") $
    hLimit 66 $
      borderWithLabel (withAttr (attrName "title") $ str " Commands ") $
        vBox $
          if null items
            then [ padLeftRight 1 $ withAttr (attrName "timestamp") $
                     str " no matching command" ]
            else [ let selected = idx == sel
                       marker = if selected then "▸ " else "  "
                       attr = if selected then "tool" else "timestamp"
                   in if isSection it
                        then padLeftRight 1 $ withAttr (attrName "timestamp") $
                               str (" " <> T.unpack (piLabel it))
                        else padLeftRight 1 $ hBox
                        [ withAttr (attrName attr) $ str marker
                        , withAttr (attrName "title") $ str (T.unpack (piId it))
                        , withAttr (attrName "timestamp") $ str "  "
                        , withAttr (attrName "timestamp") $
                            str (T.unpack (takeCells 44 (piDesc it))) ]
                 | (idx, it) <- zip [start ..]
                                   (take (end + 1) (drop start items)) ]
  where
    items = dialogCommandsItems d
    sel = dialogCommandsSelected d
    -- 30 行高的可视窗口，随光标滚动。
    (start, end) = windowRange (length items) sel 30

-- | 供应商向导卡片：进度、当前提示、已收集内容。
drawWizard :: ProviderWizard -> Widget ResourceName
drawWizard w =
  withAttr (attrName "border") $
    hLimit 72 $
      borderWithLabel (withAttr (attrName "title") $
        str (" Provider " <> show (pwStep w + 1) <> "/6 ")) $
        vBox
          [ padLeftRight 1 $ withAttr (attrName "title") $
              str (T.unpack (wizardPrompts !! pwStep w))
          , padLeftRight 1 $ withAttr (attrName "timestamp") $
              str (T.unpack (wizardSummary w))
          ]

wizardSummary :: ProviderWizard -> Text
wizardSummary w = T.intercalate "  ·  "
  [ "name " <> shown (pwName w)
  , "kind " <> shown (pwKind w)
  , "url " <> shown (pwBaseUrl w)
  , "models " <> shown (pwModels w)
  ]
  where shown t = if T.null (T.strip t) then "—" else T.strip t
