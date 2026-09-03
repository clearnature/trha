{-# LANGUAGE OverloadedStrings #-}

module Presentation.Desktop.Preload
  ( PreloadScript(..)
  , createPreloadScript
  , getPreloadScript
  ) where

import Data.Text (Text)

-- | Preload script configuration
data PreloadScript = PreloadScript
  { scriptPath :: Text
  , scriptContent :: Text
  }

-- | Create a new preload script
createPreloadScript :: Text -> Text -> PreloadScript
createPreloadScript path content = PreloadScript path content

-- | Get the preload script content
getPreloadScript :: PreloadScript -> Text
getPreloadScript script = scriptContent script