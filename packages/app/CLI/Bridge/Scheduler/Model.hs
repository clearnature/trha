{-# LANGUAGE OverloadedStrings #-}

-- | 供应商与模型端点：注册表（列出/新增/删除/切换）、端点探测、模型列表与详情。
--
-- 从 "Bridge.Scheduler" 拆出（约定见 "Bridge.Scheduler.Core"）。
module Bridge.Scheduler.Model
  ( listProviders, probeProvider, saveProvider, removeProvider, setInUseProvider
  , listModels, getModel
  , ProviderProbe(..)
  ) where

import Bridge.Scheduler.Core (SchedulerBridge(..))
import Core.Types
import Core.HTTP
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (fromJSON, parseMaybe, (.:), (.!=))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

listProviders :: SchedulerBridge -> IO (Either CLIError [ProviderInfo])
listProviders bridge = do
  result <- httpGet (bridgeHTTP bridge) "/api/providers"
    :: IO (Either CLIError Value)
  return (result >>= providerStoreToList)

-- | Ask an endpoint what it is (@POST /api/providers/probe@).  The kernel
-- classifies the model listing; the caller confirms every field.

probeProvider
  :: SchedulerBridge -> Text -> Text
  -> IO (Either CLIError ProviderProbe)
probeProvider bridge baseUrl apiKey = do
  let body = object [ "baseUrl" .= baseUrl, "apiKey" .= apiKey ]
  r <- httpPost (bridgeHTTP bridge) "/api/providers/probe" body
    :: IO (Either CLIError Value)
  return $ case r of
    Right v  -> case fromJSON v of
      Success p -> Right p
      _         -> Left (ValidationError "Invalid probe response")
    Left err -> Left err

-- | Save (or overwrite) one provider.  An empty @apiKey@ keeps the stored
-- key (the kernel treats a blank key as "unchanged").

saveProvider
  :: SchedulerBridge -> Text -> Text -> Text -> Text -> [Text] -> Text
  -> Bool -> Bool -> Text -> [Text] -> [Text]
  -> Maybe Value -> Maybe Value -> Text -> Text -> Maybe Int
  -> IO (Either CLIError [ProviderInfo])
saveProvider bridge name kind baseUrl apiKey models def authHeader noProxy effort vision efforts
             headers extraBody thinking responsesMode contextWindow = do
  let body = object
        [ "name" .= name
        , "kind" .= kind
        , "baseUrl" .= baseUrl
        , "apiKey" .= apiKey
        , "models" .= models
        , "default" .= def
        , "authHeader" .= authHeader
        , "noProxy" .= noProxy
        , "effort" .= effort
        , "efforts" .= efforts
        , "vision" .= vision
        , "headers" .= headers
        , "extraBody" .= extraBody
        , "thinking" .= thinking
        , "responsesMode" .= responsesMode
        , "contextWindow" .= contextWindow
        ]
  result <- httpPost (bridgeHTTP bridge) "/api/providers" body
    :: IO (Either CLIError Value)
  return (result >>= providerStoreToList)

-- | Remove one provider by name.

removeProvider :: SchedulerBridge -> Text -> IO (Either CLIError [ProviderInfo])
removeProvider bridge name = do
  result <- httpPost (bridgeHTTP bridge) "/api/providers/remove"
              (object ["name" .= name]) :: IO (Either CLIError Value)
  return (result >>= providerStoreToList)

-- | Make one saved provider the active one (/switch).
setInUseProvider :: SchedulerBridge -> Text -> IO (Either CLIError [ProviderInfo])
setInUseProvider bridge name = do
  r <- httpPost (bridgeHTTP bridge) "/api/providers/in-use" (object ["name" .= name])
  pure $ case r of
    Left e  -> Left e
    Right v -> providerStoreToList v

-- | Read the scheduler's effective sandbox switch (/sandbox badge).

-- | List available models (name/description/contextSize from orchestration).
listModels :: SchedulerBridge -> IO (Either CLIError [ModelInfo])
listModels bridge = do
  result <- httpGet (bridgeHTTP bridge) "/api/models" :: IO (Either CLIError [Value])
  return $ case result of
    Right raw -> Right [ mi | Object m <- raw, Just mi <- [parseModel m] ]
    Left err -> Left err
  where
    parseModel :: Object -> Maybe ModelInfo
    parseModel o = ModelInfo
      <$> parseMaybe (.: "name") o
      <*> parseMaybe (.: "description") o
      <*> parseMaybe (.: "contextSize") o

-- | Fetch a single model by name (no dedicated endpoint; explicit error).

getModel :: SchedulerBridge -> Text -> IO (Either CLIError ModelInfo)
getModel _ _ =
  return $ Left $ UnknownCLIError "getModel: not wired to orchestration API"

--------------------------------------------------------------------------------
-- Plugins (Phase 3)
--------------------------------------------------------------------------------

-- | List plugins registered on the orchestration layer.
