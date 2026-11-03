{-# LANGUAGE OverloadedStrings #-}

-- | 设置面板里的 Status / Stats 页签渲染（纯渲染层）。
--
-- 从 @UI.Brick@ 拆出的批次 2c 之一。这三个函数只把数据转成 Widget，
-- 不碰 @EventM@、不读写面板状态——面板本体（@drawSettingsPanel@）仍在
-- UI.Brick，等这一层稳定后再搬。
module UI.Render.Settings
  ( renderStatusRows
  , computeStatsBlocks
  , renderStatsBlocks
  ) where

import Brick (Widget, attrName, hBox, padLeftRight, str, vBox, withAttr)
import Brick.Widgets.Core (vLimit)
import Data.Text (Text)
import qualified Data.Text as T

import qualified UI.TextWidth as TW
import UI.I18n (Lang, tr)
import UI.State (AppState(..), msgContent, msgRole)
import UI.StatsView (StatsBlock(..), buildStatsBlocks)
import UI.StatusInfo (StatusRow(..))
import UI.State (ResourceName)

-- | Status 页签：两列（标签补齐到最宽标签的列宽）。
renderStatusRows :: Lang -> [StatusRow] -> Widget ResourceName
renderStatusRows lang rows =
  vLimit 20 $ vBox [ row r | r <- rows ]
  where
    w = 1 + maximum (map (TW.textWidth . tr lang . srLabel) rows)
    padTo x = x <> T.replicate (max 0 (w - TW.textWidth x)) " "
    row r = hBox
      [ withAttr (attrName "timestamp") (str (T.unpack (padTo (tr lang (srLabel r)))))
      , str (T.unpack (srValue r))
      ]

-- | Stats 页签的计数（形状由 UI.StatsView 定义）。
computeStatsBlocks :: AppState -> [StatsBlock]
computeStatsBlocks st =
  buildStatsBlocks sid total (u, a, tl, sy) (appLastUsage st) chars
  where
    roles = map msgRole (appMessages st)
    total = length roles
    u  = length (filter (== "user") roles)
    a  = length (filter (== "assistant") roles)
    tl = length (filter (== "tool") roles)
    sy = total - u - a - tl
    chars = sum (map (T.length . msgContent) (appMessages st))
    sid = maybe "—" T.pack (appSessionId st)

-- | 三个统计小节（每节标题 + 两列行）。
renderStatsBlocks :: Lang -> [StatsBlock] -> Widget ResourceName
renderStatsBlocks lang blocks = vBox (concatMap one blocks)
  where
    one b = [ padLeftRight 1 $ withAttr (attrName "title") $ str (T.unpack (tr lang (sbTitleKey b)))
            , renderStatusRows lang [ StatusRow k v | (k, v) <- sbRows b ]
            , str " "
            ]
