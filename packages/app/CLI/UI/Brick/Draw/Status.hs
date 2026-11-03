{-# LANGUAGE OverloadedStrings #-}

-- | 状态栏与状态摘要的**文本层**。
--
-- 从 @UI.Brick@（4400 行）分批拆出的第二层。这一层只把 'AppState' 映射成
-- 文本（模型标签、@/status@ 摘要、价格表），不构造 Widget、不碰 @EventM@——
-- 因此可以在没有终端的情况下单测。
--
-- 依赖方向：纯函数（UI.Render.Spans）← 本层 ← 渲染（drawStatus）← 交互。
-- 反向引用一律不允许。
module UI.Brick.Draw.Status
  ( modelLabel
  , pricesOf
  , statusLine
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Core.TurnStats (Prices(..), hasPrices, pricesForModel)
import Core.Types (CLIConfig(..), configPriceCached, configPriceInput, configPriceOutput)
import UI.I18n (Lang, tr)
import UI.State (AppState(..))

-- | @provider/model@ 或裸模型名（没有选中 provider 时）。
modelLabel :: AppState -> Text
modelLabel st =
  maybe (appModel st) (\p -> p <> "/" <> appModel st) (appProvider st)

-- | Prices from settings (all zero ⇒ the summary shows @≈¥—@).
-- | Settings prices win; otherwise the built-in table for the model.
pricesOf :: Text -> CLIConfig -> Prices
pricesOf model cfg =
  let cfgPrices = Prices (configPriceInput cfg) (configPriceCached cfg) (configPriceOutput cfg)
  in if hasPrices cfgPrices then cfgPrices else pricesForModel model

-- | @/status@ 的纯文本摘要。
statusLine :: AppState -> Text
statusLine st = T.unlines
  [ tr lang "Status:"
  , tr lang "  Session: " <> maybe (tr lang "none") T.pack (appSessionId st)
  , tr lang "  Model: " <> modelLabel st
  , "  " <> appStatus st
  ]
  where lang = appLang st
