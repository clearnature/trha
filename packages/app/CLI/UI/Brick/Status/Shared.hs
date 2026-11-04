{-# LANGUAGE OverloadedStrings #-}

-- | 状态栏与其他视图共用的两个小函数：provider/model 标签与价格表。
--
-- 它们被 Draw.Status 之外的 8 个模块 import（Brick / Slash / AppEvent /
-- SettingsKeys / Wizard / KeyDispatch / ChatSubmit / ToolCardMsg），所以
-- 下沉到这里、由 Draw.Status re-export，既能被 Status.Stats 复用，
-- 又不会让 Stats ↔ Status 成环。
module UI.Brick.Status.Shared
  ( modelLabel, pricesOf
  ) where

import Core.TurnStats (Prices(..), hasPrices, pricesForModel)
import Core.Types (CLIConfig(..))
import Data.Text (Text)
import UI.State (AppState, appModel, appProvider)

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
