{-# LANGUAGE OverloadedStrings #-}

module Client.Model
  ( -- * Model Client
    ModelClient(..)
  , createModelClient
  
    -- * Model Operations
  , list
  , get
  ) where

import Core.Types
import Core.Client
import Core.HTTP
import Data.Text (Text)

-- | Model client
data ModelClient = ModelClient
  { modelClientSDK :: SDKClient
  }

-- | Create a new model client
createModelClient :: SDKClient -> ModelClient
createModelClient sdk = ModelClient sdk

-- | List all models
list :: ModelClient -> IO (Either SDKError [ModelInfo])
list client = Core.Client.listModels (modelClientSDK client)

-- | Get a model by name
get :: ModelClient -> Text -> IO (Either SDKError ModelInfo)
get client modelName = Core.Client.getModel (modelClientSDK client) modelName