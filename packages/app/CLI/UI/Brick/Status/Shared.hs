{-# LANGUAGE OverloadedStrings #-}

-- | 状态栏与其他视图共用的两个小函数：provider/model 标签与价格表。
--
-- 它们被 Draw.Status 之外的 8 个模块 import（Brick / Slash / AppEvent /
-- SettingsKeys / Wizard / KeyDispatch / ChatSubmit / ToolCardMsg），所以
-- 下沉到这里、由 Draw.Status re-export，既能被 Status.Stats 复用，
-- 又不会让 Stats ↔ Status 成环。
module UI.Brick.Status.Shared
  ( modelLabel, pricesOf, hasPricesFor
  ) where

import Core.TurnStats
  ( Prices(..), hasPrices, pricesAt, pricesForModel, pricesPeakForModel )
import Core.Types (CLIConfig(..))
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import UI.State (AppState, appModel, appProvider)

modelLabel :: AppState -> Text
modelLabel st =
  maybe (appModel st) (\p -> p <> "/" <> appModel st) (appProvider st)

-- | Prices from settings (all zero ⇒ the summary shows @≈¥—@).
--
-- Settings prices win and are flat (the user chose one card).  Otherwise the
-- built-in table picks base vs peak by the turn's clock: a cached turn at
-- 20:00 Beijing bills the off-peak card, not the peak one.
pricesOf :: Text -> CLIConfig -> UTCTime -> Prices
pricesOf model cfg at =
  let cfgPrices = Prices (configPriceInput cfg) (configPriceCached cfg) (configPriceOutput cfg)
  in if hasPrices cfgPrices
       then cfgPrices
       else pricesAt at (pricesForModel model) (pricesPeakForModel model)

-- | Whether a price is known for the model, independent of the clock.  The
-- status line uses this only to decide between @¥12.34@ and @¥—@; the actual
-- card is already folded into 'appLastCost' / 'appCostSum' when the turn ends.
hasPricesFor :: Text -> CLIConfig -> Bool
hasPricesFor model cfg =
  let cfgPrices = Prices (configPriceInput cfg) (configPriceCached cfg) (configPriceOutput cfg)
  in hasPrices cfgPrices || hasPrices (pricesForModel model)

-- | @/status@ 的纯文本摘要。
