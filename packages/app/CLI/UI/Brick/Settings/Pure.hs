{-# LANGUAGE OverloadedStrings #-}

-- | 设置面板的纯函数层：页签移动、编辑态判定、取值种子、下标钳制、选项循环、
-- 列表宽度。全部无副作用（不碰 EventM），因此可以从 SettingsKeys 里单独拆出并单测。
module UI.Brick.Settings.Pure
  ( moveTab, editingNow, seedEdit, clampSel, nextOption, settingsListWidth
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import UI.SettingsView (SettingsEntry(..))
import UI.State (AppState, SettingsPanel(..), SettingsTab(..), appSettings)

moveTab :: Int -> SettingsTab -> SettingsTab
moveTab d t = toEnum (mod (fromEnum t + d) (fromEnum (maxBound :: SettingsTab) + 1))
-- | Keys while the settings panel is open (three-zone focus model, mirroring
-- the reference dialog: tabs -> search -> list -> editing).
-- | handleSettingsKey 见 UI.Brick.KeyDispatch。

editingNow :: AppState -> Bool
editingNow st = case appSettings st of
  Just p | Just _ <- spEdit p -> True
  _ -> False

-- | Tab-bar switching shared by left/right keys.

seedEdit :: SettingsEntry -> Text
seedEdit e
  | seKey e == "token" = ""
  | otherwise = seVal e

-- | Widget for the settings panel (tab bar + content).
-- | drawSettingsPanel 见 UI.Brick.Draw.Settings（随 settingsRows/visibleRows 一起迁出）。

-- | Clamp a selection into @[0, n-1]@.

clampSel :: Int -> Int -> Int
clampSel n sel
  | n <= 0 = 0
  | otherwise = max 0 (min sel (n - 1))

-- | Two-column rendering of the Status rows (label column padded).
-- | renderStatusRows / computeStatsBlocks / renderStatsBlocks 见 UI.Render.Settings。


-- | Next element in a cycle (wraps to the head); falls back to the head
-- when the current value is not one of the options.

nextOption :: [Text] -> Text -> Text
nextOption opts cur = case break (== cur) opts of
  (_, [])     -> case opts of
    (x : _) -> x
    []      -> ""
  (_, x : rest) -> case rest of
    (nxt : _) -> nxt
    []        -> case opts of
      (h : _) -> h
      []      -> x

-- | Maximum panel row width (kept below the 80-column window).

settingsListWidth :: Int
settingsListWidth = 96

-- | Current git branch name, or a short SHA when detached, or "—".  Asking
-- git itself resolves worktrees, packed refs and detached HEAD correctly;
-- reading @.git/refs/heads/<branch>@ returns the commit SHA, not the name.
