{-# LANGUAGE OverloadedStrings #-}

-- | 消息区的鼠标选区：屏幕行 → 消息下标、拖选、复制、松开收尾。
--
-- 从 @UI.Brick@ 的交互层拆出。这组函数只读消息高度与 'AppState' 的选区字段
-- （@appSelStart@ / @appSelEnd@），唯一的副作用是写剪贴板与弹一条 toast。
module UI.Brick.Selection
  ( msgIndexAt
  , msgHeight
  , msgRowAt
  , beginSel
  , extendSel
  , copySelectionText
  , finishSel
  , copyToClipboard
  , toolCardIds
  , moveCardFocus
  , toggleFocusedCard
  ) where

import Brick (EventM, get, modify)
import Control.Exception (IOException, try)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)

import Core.Clipboard (copyToClipboard)
import UI.Brick.DialogKeys (scrollBottom)
import UI.Brick.Draw.Messages (cardHidden)
import UI.Event (nextCardFocus)
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)

import UI.Brick.Toast (showToast)
import UI.Render.ToolCard (ToolFold(..), toggleFold)
import UI.State (AppState(..), ChatMessage(..), ResourceName(..))

-- | Message under a screen row (approximate: content lines + 2).
msgIndexAt :: Int -> AppState -> Maybe Int
msgIndexAt y st =
  let hs = [ msgHeight st m | m <- appMessages st ]
      tops = scanl (+) 0 hs
  in listToMaybe [ i | i <- [0 .. length hs - 1], y >= tops !! i, y < tops !! (i + 1) ]

-- | Screen rows a message occupies (a folded reasoning block is one line).
msgHeight :: AppState -> ChatMessage -> Int
msgHeight st m
  | msgRole m == "thinking"
  , Map.lookup (msgId m) (appFolds st) /= Just FoldExpanded = 1
  | otherwise = max 1 (length (T.lines (msgContent m))) + 2

-- | A terminal row → the message area's row: the box border + title take two
-- rows, and the viewport may be scrolled.  Without this every click landed on
-- the wrong message, so the thinking triangle never toggled.
msgRowAt :: Int -> EventM ResourceName AppState Int
msgRowAt y = do
  st <- get
  -- The message box contributes a border + title (2 rows); a visible toast
  -- adds its own 3-row box above it.
  let toastRows = maybe 0 (const 3) (appToast st)
  pure (max 0 (y - 2 - toastRows))

beginSel :: Int -> EventM ResourceName AppState ()
beginSel y = do
  st <- get
  rel <- msgRowAt y
  let i = fromMaybe 0 (msgIndexAt rel st)
  modify $ \s -> s { appSelStart = Just i, appSelEnd = Just i }

extendSel :: Int -> EventM ResourceName AppState ()
extendSel y = do
  st <- get
  rel <- msgRowAt y
  case appSelStart st of
    Nothing -> return ()
    Just _  -> modify $ \s -> s { appSelEnd = Just (fromMaybe 0 (msgIndexAt rel s)) }

-- | 复制当前选区的文本。@clearSel@ 决定复制后是否清空选区：
-- 鼠标松开时保留高亮（用户还能接着调整，Ctrl+C 才清掉），Ctrl+C 复制后清空。
copySelectionText :: Bool -> EventM ResourceName AppState ()
copySelectionText clearSel = do
  st <- get
  case appSelStart st of
    Nothing -> pure ()
    Just a0 -> do
      let b0 = fromMaybe a0 (appSelEnd st)
          lo = min a0 b0
          hi = max a0 b0
          txt = T.intercalate "\n\n"
                  [ msgContent m | m <- appMessages st, msgId m >= lo, msgId m <= hi ]
      when (not (T.null (T.strip txt))) $ do
        ok <- liftIO (copyToClipboard txt)
        showToast (if ok then "Copied" else "Clipboard unavailable")
      when clearSel $
        modify $ \s -> s { appSelStart = Nothing, appSelEnd = Nothing }

finishSel :: Int -> EventM ResourceName AppState ()
finishSel y = do
  st <- get
  case appSelStart st of
    Nothing -> return ()
    Just a0 -> do
      let b0 = fromMaybe a0 (appSelEnd st)
          lo = min a0 b0
          hi = max a0 b0
          isThinking = any (\m -> msgId m == a0 && msgRole m == "thinking") (appMessages st)
      if a0 == b0 && isThinking
        then modify $ \s -> s
               { appFolds = Map.alter (Just . toggleFold . fromMaybe FoldCollapsed) a0 (appFolds s)
               , appSelStart = Nothing, appSelEnd = Nothing }
        -- 松开鼠标时复制但**保留**选区：高亮还在，Ctrl+C 仍可复制，
        -- 也还能继续拖选调整。清空只发生在 Ctrl+C 之后。
        else copySelectionText False

-- | copyToClipboard 实现移至 Core.Clipboard（REPL 的 /copy 也要用），
-- 本模块保留 re-export 以免波及 ~30 个既有点名的导入清单。
toolCardIds :: AppState -> [Int]
toolCardIds st = [ msgId m | m <- appMessages st, isJust (msgTool m), not (cardHidden st m) ]

-- | Move the tool-card focus (alt+↑/↓), clamped to the newest/oldest card.
moveCardFocus :: Int -> EventM ResourceName AppState ()
moveCardFocus delta = do
  st <- get
  let ids = toolCardIds st
  modify $ \s -> s { appCardFocus = nextCardFocus ids (appCardFocus s) delta }
  scrollBottom

-- | Toggle the focused card (ctrl+o, or Enter on empty input).  With no focus
-- yet this picks the newest card, then flips it — the old single-card
-- behaviour, now with a movable focus (MiMo parity).
toggleFocusedCard :: EventM ResourceName AppState ()
toggleFocusedCard = do
  st <- get
  let ids = toolCardIds st
  case nextCardFocus ids (appCardFocus st) 0 of
    Nothing -> return ()
    Just mid ->
      modify $ \s -> s { appCardFocus = Just mid
                       , appFolds = Map.alter (Just . toggleFold . fromMaybe FoldCollapsed) mid (appFolds s) }
  scrollBottom

