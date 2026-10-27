{-# LANGUAGE OverloadedStrings #-}

-- | Model favourites and recents (MiMo's model dialog): favourites pin a
-- model to the top, recents follow in most-recently-used order, the rest keep
-- the provider's order.
module UI.ModelPrefs
  ( ModelPrefs(..)
  , emptyModelPrefs
  , maxRecentModels
  , toggleFavorite
  , recordRecent
  , isFavorite
  , orderedModels
  , defaultModelPrefsPath
  , loadModelPrefs
  , saveModelPrefs
  ) where

import Control.Exception (IOException, try)
import Core.Types (ModelInfo(..))
import Data.Aeson (FromJSON(..), ToJSON(..), eitherDecodeStrict', encode, object, withObject, (.:?), (.!=), (.=))
import qualified Data.ByteString.Lazy as BL
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, renameFile)
import System.FilePath ((</>))
import Core.StatePaths (stateReadPath, stateWritePath)

data ModelPrefs = ModelPrefs
  { mpFavorites :: [Text]  -- ^ pinned, newest first
  , mpRecent    :: [Text]  -- ^ most recently selected, newest first
  } deriving (Show, Eq)

emptyModelPrefs :: ModelPrefs
emptyModelPrefs = ModelPrefs [] []

maxRecentModels :: Int
maxRecentModels = 5

instance ToJSON ModelPrefs where
  toJSON p = object
    [ "favorites" .= mpFavorites p
    , "recent" .= mpRecent p
    ]

instance FromJSON ModelPrefs where
  parseJSON = withObject "ModelPrefs" $ \o ->
    ModelPrefs <$> o .:? "favorites" .!= [] <*> o .:? "recent" .!= []

-- | Pin/unpin a model.
toggleFavorite :: Text -> ModelPrefs -> ModelPrefs
toggleFavorite name p
  | name `elem` mpFavorites p = p { mpFavorites = filter (/= name) (mpFavorites p) }
  | otherwise                = p { mpFavorites = nub (name : mpFavorites p) }

-- | Record a selection (moves it to the front, caps the list).
recordRecent :: Text -> ModelPrefs -> ModelPrefs
recordRecent name p =
  p { mpRecent = take maxRecentModels (nub (name : filter (/= name) (mpRecent p))) }

isFavorite :: Text -> ModelPrefs -> Bool
isFavorite name = elem name . mpFavorites

-- | Dialog order: favourites, recents, then the provider's order.
orderedModels :: ModelPrefs -> [ModelInfo] -> [ModelInfo]
orderedModels p ms = favs ++ recents ++ rest
  where
    byName n = [ m | m <- ms, modelName m == n ]
    favs = concatMap byName (mpFavorites p)
    recents = concatMap byName (filter (`notElem` mpFavorites p) (mpRecent p))
    rest =
      [ m | m <- ms
      , modelName m `notElem` mpFavorites p
      , modelName m `notElem` mpRecent p ]

-- | @~/.trha/state/models.json@ (legacy @~/.trha/models.json@ is read).
defaultModelPrefsPath :: IO FilePath
defaultModelPrefsPath = stateReadPath "models.json"

loadModelPrefs :: IO ModelPrefs
loadModelPrefs = do
  path <- defaultModelPrefsPath
  exists <- doesFileExist path
  if not exists
    then pure emptyModelPrefs
    else do
      body <- TIO.readFile path `catchIO` const (pure "")
      pure $ case eitherDecodeStrict' (TE.encodeUtf8 body) of
        Right p -> p
        Left _  -> emptyModelPrefs

saveModelPrefs :: ModelPrefs -> IO ()
saveModelPrefs p = do
  path <- stateWritePath "models.json"
  let tmp = path ++ ".tmp"
  TIO.writeFile tmp (TE.decodeUtf8 (BL.toStrict (encode p)))
  renameFile tmp path `catchIO` const (pure ())

catchIO :: IO a -> (IOException -> IO a) -> IO a
catchIO action handler = do
  r <- try action
  case r of
    Left e  -> handler e
    Right a -> pure a
