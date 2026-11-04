{-# LANGUAGE OverloadedStrings #-}

-- | 消息区的渲染：消息头、正文、工具卡、markdown 块。
--
-- 依赖方向：UI.Render.{Markdown,ToolCard,Message,Diff,Spans} ← 本模块 ← UI.Brick（装配）。
--
-- 与 drawDialog 的教训一致：一次只搬一组同职责函数，每步都能编译。
module UI.Brick.Draw.Messages
  ( cardHidden
  , roleStyle
  , messageHeader
  ) where

import Brick (AttrName, Widget, attrName, emptyWidget, hBox, str, withAttr)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as Map

import UI.Render.Message (classifyError, errorLabel)
import UI.Render.ToolCard (ToolFold(..))
import UI.Render.ToolSummary (shouldHideTool)
import UI.State (AppState(..), ChatMessage(..), ResourceName(..))

-- | 工具卡是否折叠隐藏（verbose 模式全展开；否则看用户折叠状态）。
cardHidden :: AppState -> ChatMessage -> Bool
cardHidden st m
  | appVerbose st = False
  | Map.lookup (msgId m) (appFolds st) == Just FoldExpanded = False
  | otherwise = maybe False shouldHideTool (msgTool m)

-- | 消息角色的显示样式：(属性, 括号标签)。
--
-- 错误按种类分类，让限流显示成限流而不是笼统失败（MiMo 的 @errorKind()@）。
roleStyle :: Text -> Text -> (AttrName, Text)
roleStyle role content = case role of
  "user"      -> (attrName "user", role)
  "assistant" -> (attrName "assistant", role)
  "tool"      -> (attrName "tool", role)
  "plan"      -> (attrName "plan", role)
  "system"    -> (attrName "system", role)
  "error"     -> (attrName "error", errorLabel (classifyError content))
  "thinking"  -> (attrName "system", "thinking")
  "step"      -> (attrName "timestamp", "step")
  "stats"     -> (attrName "timestamp", "stats")
  "compact"   -> (attrName "plan", "context")
  "retry"     -> (attrName "busy", "retry")
  "shell"     -> (attrName "tool", "shell")
  _           -> (attrName "header", role)

-- | 消息与流式块共用的表头行：@[role] timestamp@。
messageHeader :: Bool -> Text -> Text -> Text -> Widget ResourceName
messageHeader showTs role content time
  -- 每轮的记账行是纯文本行，不带括号。
  | role == "stats" = emptyWidget
  | otherwise = hBox (roleW : [timeW | showTs])
  where
    sty = roleStyle role content
    roleW = withAttr (fst sty) $ str $ "[" ++ T.unpack (snd sty) ++ "]"
    timeW = hBox [str " ", withAttr (attrName "timestamp") (str (T.unpack time))]
