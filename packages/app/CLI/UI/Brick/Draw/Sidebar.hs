{-# LANGUAGE OverloadedStrings #-}

-- | 侧栏与输入区补全面板的渲染。
--
-- 从 @UI.Brick@ 分批拆出的第三层（批次 2a）。这一层只做 Widget 装配，
-- 数据装配（'SidebarData'）与行生成（'sidebarLines'）留在 UI.Render.Sidebar，
-- 状态到数据的映射（'sidebarDataFor'）跟着本模块走。
--
-- 依赖方向：UI.Render.Sidebar ← 本模块 ← UI.Brick（装配）。
module UI.Brick.Draw.Sidebar
  ( drawSidebar
  , drawCompletion
  , sidebarDataFor
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Brick
  ( Widget, attrName, fill, hBox, hLimit, padLeftRight
  , str, vBox, withAttr )
import Brick.Widgets.Border (borderWithLabel)

import UI.Brick.Draw.Status (modelLabel)
import UI.Completion (CompletionState(..), compPath, csItems, csSel)
import UI.I18n (tr)
import UI.Render.Sidebar
  ( SidebarData(..), SidebarLine(..), sidebarHint, sidebarLines, truncateTo )
import UI.State (AppState(..), ResourceName(..))

-- | 右侧栏：边框 + 内容行 + 提示行，底部 @fill@ 让边框撑满整列高度
-- （MiMo 的侧栏是通高面板，不是随文字结束的盒子）。
drawSidebar :: AppState -> Int -> Widget ResourceName
drawSidebar st sw =
  withAttr (attrName "border") $
    hLimit sw $
      borderWithLabel (withAttr (attrName "title") $ str " Sidebar ") $
        vBox ( [ withAttr (attrName (slAttr l)) $ str (T.unpack (slText l))
               | l <- sidebarLines (max 1 (sw - 2)) (sidebarDataFor st) ]
               ++ [ fill ' ' ]
               ++ [ withAttr (attrName "timestamp")
                      (str (T.unpack (truncateTo (max 1 (sw - 2))
                                       (sidebarHint (appLang st))))) ] )

-- | 输入框上方的 @\@@ 补全列表（就地展开，不抢编辑器焦点的居中弹窗）。
drawCompletion :: AppState -> CompletionState -> Widget ResourceName
drawCompletion _ cs =
  withAttr (attrName "tool") $
    hLimit 60 $
      borderWithLabel (withAttr (attrName "title") $ str " @ files ") $
        vBox
          [ let selected = idx == csSel cs
                marker = if selected then "▸ " else "  "
                attr = if selected then "tool" else "timestamp"
            in padLeftRight 1 $ hBox
                 [ withAttr (attrName attr) $ str marker
                 , withAttr (attrName "title") $ str (T.unpack (compPath c)) ]
          | (idx, c) <- zip [0 ..] (take 8 (csItems cs)) ]

-- | 把实时状态收成侧栏需要的数据形状。
sidebarDataFor :: AppState -> SidebarData
sidebarDataFor st = SidebarData
  { sdUsage     = appUsage st
  , sdCtxSize   = appCtxSize st
  , sdTodos     = appTodos st
  , sdSessionId = T.pack <$> appSessionId st
  , sdTitle     = appSessionTitle st
  , sdModel     = modelLabel st
  , sdCwd       = appCwd st
  , sdFiles     = appFiles st
  , sdGoal      = appGoal st
  , sdInstructions = appInstructions st
  , sdAgents    = appAgents st
  , sdLsp       = appLsp st
  , sdMcp       = appMcp st
  }
