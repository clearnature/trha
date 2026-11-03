{-# LANGUAGE OverloadedStrings #-}

-- | 设置面板（settings）的渲染。
--
-- 从 @UI.Brick@ 拆出的批次 2c。面板本体的数据装配（settingsRows /
-- visibleRows）与渲染（drawSettingsPanel）一起搬来；Status/Stats 页签的
-- 具体行渲染在 UI.Render.Settings，条目筛选与脱敏在 UI.SettingsView。
module UI.Brick.Draw.Settings
  ( drawSettingsPanel
  , settingsRows
  , visibleRows
  , settingsListMax
  ) where

import Brick
  ( Widget, attrName, emptyWidget, fill, hBox, padLeftRight, str, vBox, withAttr )
import Brick.Widgets.Border (borderWithLabel)
import Brick.Widgets.Core (vLimit)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Graphics.Vty as V

import Core.Types (ProviderInfo(..))
import UI.I18n (tr)
import UI.Render.Picker (windowRange)
import UI.Render.Settings (computeStatsBlocks, renderStatsBlocks, renderStatusRows)
import UI.SettingsView
  ( SettingsEntry(..), filterEntries, isOverridden, maskSecret, settingsEntries )
import UI.State
  ( AppState(..), ResourceName(..), SettingsFocus(..), SettingsPanel(..)
  , SettingsTab(..), tabLabel, tabList )
import UI.TextWidth (takeCells)

settingsRows :: AppState -> [SettingsEntry]
settingsRows st = settingsEntries (appLang st) (appEffCfg st)

-- | Filtered rows currently shown in the settings tab.
visibleRows :: AppState -> [SettingsEntry]
visibleRows st = filterEntries q (settingsRows st)
  where
    q = maybe "" spQuery (appSettings st)

drawSettingsPanel :: AppState -> Widget ResourceName
drawSettingsPanel st =
  withAttr (attrName "border") $
    borderWithLabel (withAttr (attrName "title") $ str (T.unpack (tr lang " settings "))) $
      vBox (tabBarRow : contentRows ++ [fill ' '])
  where
    lang = appLang st
    p = case appSettings st of
      Just x  -> x
      Nothing -> SettingsPanel TabSettings FocusList 0 "" Nothing Nothing
    -- make one row span the full dialog width (fill absorbs the rest)
    fullRow w = vLimit 1 $ hBox [padLeftRight 1 w, fill ' ']
    fullRowAny w = hBox [padLeftRight 1 w, fill ' '] -- single line vs. multi-line content
    tabBarRow = fullRow $ hBox
      [ hBox (map tabWidget tabList)
      , str "  "
      , withAttr (attrName "status") (str (T.unpack hintText))
      ]
    tabWidget t =
      let active = spTab p == t
          label = " " <> tabLabel lang t <> " "
          attr  = if active then attrName "tool" else attrName "timestamp"
      in withAttr attr (str (T.unpack label))
    hintText = case spFocus p of
      FocusTabs -> tr lang "←/→ to switch tabs"
      FocusSearch -> tr lang "↑ tabs · ↓ list · type to filter"
      FocusList -> case spEdit p of
        Just _  -> tr lang "Enter save · Esc cancel"
        Nothing -> tr lang "↑/↓ move · Enter edit · Esc close"
          <> "  " <> tr lang "←/→ to switch tabs"
    contentRows = case spTab p of
      TabSettings -> settingsListRows
      TabStatus   -> [fullRowAny (renderStatusRows lang (appSysRows st))]
      TabStats    -> [fullRowAny (vLimit 22 (renderStatsBlocks lang (computeStatsBlocks st)))]
      TabProviders -> providerListRows
    settingsListRows = fullRow (searchRow st p) : map fullRow rowsShown ++ [fullRow descRow, fullRow statusRow]
    -- Providers 页签（tui-port L290）：registry 一览；选中行支持
    -- Enter=选为当前 provider、t=思考开关、d=删除确认。
    providerListRows =
      let ps = appProviders st
      in if null ps
           then [fullRow (padLeftRight 1 (str " no providers"))]
           else map fullRowAny [rowForProvider idx p2 | (idx, p2) <- zip [0 ..] ps]
    rowForProvider idx p2 =
      let body = hBox
            [ withAttr (attrName "title") (str (T.unpack (takeCells 22 (piName p2))))
            , str "  "
            , str (T.unpack (takeCells 10 (piKind p2)))
            , str "  "
            , str (T.unpack (takeCells 18 (piDefault p2)))
            , str "  "
            , str (T.unpack (piEffort p2 <> "/" <> piThinking p2))
            ]
      in if idx == sel
           then withAttr (attrName "selection") body
           else withAttr (attrName "timestamp") body
    searchRow st2 sp =
      let q = spQuery sp
          n = length (filterEntries q (settingsRows st2))
          left = if T.null q then tr (appLang st2) "Settings" else tr (appLang st2) "Search: " <> q
      in hBox
        [ withAttr (attrName "input") $ str (T.unpack left)
        , str "   "
        , withAttr (attrName "status") $ str (T.unpack (searchRight sp n))
        ]
    searchRight sp n = case spEdit sp of
      Just buf  -> tr lang "editing " <> buf <> "   " <> tr lang "Enter save · Esc cancel"
      Nothing
        | n == 0 -> tr lang "no match"
        | otherwise -> "[" <> T.pack (show n) <> "]"
          <> maybe "" ("  " <>) (spError sp)
    rowsShown = map (padLeftRight 1 . rowFor) [start .. min end (n - 1)]
    visible = visibleRows st
    n = length visible
    sel = spSel p
    editing = case spEdit p of
      Just _  -> True
      Nothing -> False
    (start, end) = windowRange n sel settingsListMax
    rowFor idx = case drop idx visible of
      e : _ -> if idx == sel
        then withAttr (attrName "selection") (fullRow (rowBody e))
        else withAttr (attrName "timestamp") (fullRow (rowBody e))
      [] -> emptyWidget
    -- qwen-style row: label left, fill, value pinned right; * = overridden
    rowBody e = hBox
      [ withAttr (attrName "title") (str (T.unpack (takeCells 30 (seLabel e))))
      , fill ' '
      , str (T.unpack (takeCells 30 valueText))
      ]
      where
        valueText | seKey e == "token" = maskSecret (seVal e)
                  | otherwise = seVal e
          <> (if isOverridden e then " *" else "")
    -- qwen-style detail line: full description of the selected row
    descRow = case drop sel visible of
      e : _ | not editing && n > 0 ->
        withAttr (attrName "timestamp") $ str (T.unpack (takeCells 70 (seHint e)))
      _ -> emptyWidget
    -- bottom help line
    statusRow = padLeftRight 1 $ withAttr (attrName "status") $ str (T.unpack helpText)
    helpText
      | editing = tr lang "Enter save · Esc cancel"
      | otherwise = tr lang "↑/↓ move · Enter edit · Esc close"

-- | Clamp a selection into @[0, n-1]@.

settingsListMax :: Int
settingsListMax = 20
