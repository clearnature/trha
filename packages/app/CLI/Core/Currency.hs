{-# LANGUAGE OverloadedStrings #-}

-- | Manually maintained currency rates for @/currency@.
--
-- No network call: the file @~/.trha/currency.json@ is edited by hand or with
-- @/currency set CODE RATE@, and stays valid until the next update.  Amounts
-- in other currencies are converted through the table's base.
module Core.Currency
  ( CurrencyTable (..)
  , defaultCurrencyTable
  , loadCurrency
  , saveCurrency
  , convertCurrency
  , rateFor
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=), (.!=))
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesFileExist, renameFile)
import System.FilePath ((</>))
import Core.StatePaths (stateReadPath, stateWritePath)

-- | Base currency plus one rate per currency (1 base = N currency).
data CurrencyTable = CurrencyTable
  { ctBase      :: Text
  , ctRates     :: Map Text Double
  , ctUpdatedAt :: Maybe Text
  } deriving (Show, Eq)

instance ToJSON CurrencyTable where
  toJSON c = object
    [ "base" .= ctBase c
    , "rates" .= Map.toList (ctRates c)
    , "updatedAt" .= ctUpdatedAt c
    ]

instance FromJSON CurrencyTable where
  parseJSON = withObject "CurrencyTable" $ \o ->
    CurrencyTable
      <$> (o .:? "base" .!= "CNY")
      <*> (Map.fromList <$> o .:? "rates" .!= [])
      <*> o .:? "updatedAt"

defaultCurrencyTable :: CurrencyTable
defaultCurrencyTable = CurrencyTable "CNY" (Map.fromList [("CNY", 1)]) Nothing

-- | @~/.trha/state/currency.json@ (legacy @~/.trha/currency.json@ is read).
currencyPath :: IO FilePath
currencyPath = stateReadPath "currency.json"

-- | Load the table (missing file yields the default).
loadCurrency :: IO CurrencyTable
loadCurrency = do
  path <- currencyPath
  exists <- doesFileExist path
  if not exists
    then pure defaultCurrencyTable
    else do
      raw <- BL.readFile path
      pure $ fromMaybe defaultCurrencyTable (A.decode raw)

-- | Atomic write (temp file + rename), like settings.
saveCurrency :: CurrencyTable -> IO ()
saveCurrency c = do
  path <- stateWritePath "currency.json"
  let tmp = path <> ".tmp"
  BL.writeFile tmp (A.encode c)
  renameFile tmp path

-- | Rate for one currency against the base (1 base = rate currency).
rateFor :: CurrencyTable -> Text -> Maybe Double
rateFor c code =
  let k = T.toUpper (T.strip code)
  in if k == T.toUpper (ctBase c) then Just 1 else Map.lookup k (ctRates c)

-- | Convert an amount between two currencies through the base.
convertCurrency :: CurrencyTable -> Text -> Text -> Double -> Maybe Double
convertCurrency c from to amount = do
  a <- rateFor c from
  b <- rateFor c to
  if a == 0 then Nothing else pure (amount / a * b)
