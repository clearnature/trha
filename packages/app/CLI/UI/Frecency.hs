{-# LANGUAGE OverloadedStrings #-}

-- | Command-panel frecency (MiMo's `frecency.tsx`): commands you actually
-- use drift to the top of the palette, while the registry order remains the
-- tie-breaker (stable sort, so an unused palette looks exactly as before).
module UI.Frecency
  ( Frecency(..)
  , emptyFrecency
  , recordUse
  , scoreOf
  , rankItems
  , defaultFrecencyPath
  , loadFrecency
  , saveFrecency
  ) where

import Control.Exception (IOException, try)
import Data.Aeson (FromJSON(..), ToJSON(..), eitherDecodeStrict', encode, object, withObject, (.:?), (.!=), (.=))
import qualified Data.ByteString.Lazy as BL
import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, renameFile)
import System.FilePath ((</>))
import Core.StatePaths (stateReadPath, stateWritePath)
import UI.Render.Picker (PickerItem(..))

-- | Usage counts keyed by item id (the slash command or @/skill:<name>@).
newtype Frecency = Frecency { frecCounts :: Map.Map Text Int }
  deriving (Show, Eq)

emptyFrecency :: Frecency
emptyFrecency = Frecency Map.empty

instance ToJSON Frecency where
  toJSON (Frecency m) = object ["counts" .= m]

instance FromJSON Frecency where
  parseJSON = withObject "Frecency" $ \o ->
    Frecency <$> o .:? "counts" .!= Map.empty

-- | Count one use of @key@.
recordUse :: Text -> Frecency -> Frecency
recordUse key (Frecency m) = Frecency (Map.insertWith (+) key 1 m)

scoreOf :: Text -> Frecency -> Int
scoreOf key (Frecency m) = Map.findWithDefault 0 key m

-- | Sort by usage count (descending), keeping the input order for equal
-- scores.  Items with no history therefore stay where the registry put them.
rankItems :: Frecency -> [PickerItem] -> [PickerItem]
rankItems fr = sortBy (\a b -> compare (scoreOf (piId b) fr) (scoreOf (piId a) fr))

-- | @~/.trha/state/frecency.json@ (a legacy @~/.trha/frecency.json@ is
-- still read; new writes go to @state/@).
defaultFrecencyPath :: IO FilePath
defaultFrecencyPath = stateReadPath "frecency.json"

-- | Load usage counts (missing/unreadable file = empty).
loadFrecency :: IO Frecency
loadFrecency = do
  path <- defaultFrecencyPath
  exists <- doesFileExist path
  if not exists
    then pure emptyFrecency
    else do
      body <- TIO.readFile path `catchIO` const (pure "")
      pure $ case eitherDecodeStrict' (TE.encodeUtf8 body) of
        Right fr -> fr
        Left _   -> emptyFrecency

-- | Persist atomically (tmp + rename).
saveFrecency :: Frecency -> IO ()
saveFrecency fr = do
  path <- stateWritePath "frecency.json"
  let tmp = path ++ ".tmp"
  TIO.writeFile tmp (TE.decodeUtf8 (BL.toStrict (encode fr)))
  renameFile tmp path `catchIO` const (pure ())

catchIO :: IO a -> (IOException -> IO a) -> IO a
catchIO action handler = do
  r <- try action
  case r of
    Left e  -> handler e
    Right a -> pure a
