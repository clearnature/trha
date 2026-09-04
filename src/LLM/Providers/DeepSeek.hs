{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

-- | DeepSeek API provider — real HTTP calls to DeepSeek's OpenAI-compatible API
module LLM.Providers.DeepSeek
  ( createDeepSeekProvider
  ) where

import LLM.Adapter.Types
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BSL
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.Vector as V
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import Network.HTTP.Types.Status
import GHC.Generics

import LLM.Adapter.Interface (LLMAdapter(..))

-- | DeepSeek API response types
data ChatResponse = ChatResponse
  { crId      :: Text
  , crObject  :: Text
  , crChoices :: [Choice]
  , crUsage   :: Maybe RespUsage
  } deriving (Show, Generic)

data Choice = Choice
  { chIndex   :: Int
  , chMessage :: RespMessage
  , chFinishReason :: Maybe Text
  } deriving (Show, Generic)

data RespMessage = RespMessage
  { rmRole    :: Text
  , rmContent :: Text
  } deriving (Show, Generic)

data RespUsage = RespUsage
  { ruPromptTokens     :: Int
  , ruCompletionTokens :: Int
  , ruTotalTokens      :: Int
  } deriving (Show, Generic)

instance FromJSON ChatResponse where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 2 }
instance FromJSON Choice where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 2 }
instance FromJSON RespMessage where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 2 }
instance FromJSON RespUsage where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 2 }

-- | Create a DeepSeek provider with real API calls
createDeepSeekProvider :: Text -> IO LLMAdapter
createDeepSeekProvider apiKey = do
  manager <- newManager tlsManagerSettings
  let baseUrl = "https://api.deepseek.com"

  return $ LLMAdapter
    { llmChat = \messages -> do
        let requestBody = object
              [ "model"    .= ("deepseek-chat" :: Text)
              , "messages" .= map toJSON messages
              , "stream"   .= False
              ]

        initialRequest <- parseRequest (T.unpack baseUrl ++ "/v1/chat/completions")
        let request = initialRequest
              { method = "POST"
              , requestBody = RequestBodyLBS (encode requestBody)
              , requestHeaders =
                  [ ("Content-Type", "application/json")
                  , ("Authorization", "Bearer " <> TE.encodeUtf8 apiKey)
                  ]
              }

        response <- httpLbs request manager
        if statusIsSuccessful (responseStatus response)
          then case decode (responseBody response) of
            Just cr -> do
              let content = case crChoices cr of
                    (c:_) -> rmContent (chMessage c)
                    []    -> "No response"
              let usage = case crUsage cr of
                    Just u  -> Usage (ruPromptTokens u) (ruCompletionTokens u) (ruTotalTokens u)
                    Nothing -> Usage 0 0 0
              return [ChunkDelta content, ChunkDone usage]
            Nothing -> return [ChunkError "Failed to parse DeepSeek response"]
          else return [ChunkError $ "DeepSeek API error: " <> T.pack (show (statusCode (responseStatus response)))]

    , llmEmbed = \text -> do
        -- DeepSeek embedding endpoint
        let requestBody = object
              [ "model" .= ("deepseek-embedding" :: Text)
              , "input" .= text
              ]
        initialRequest <- parseRequest (T.unpack baseUrl ++ "/v1/embeddings")
        let request = initialRequest
              { method = "POST"
              , requestBody = RequestBodyLBS (encode requestBody)
              , requestHeaders =
                  [ ("Content-Type", "application/json")
                  , ("Authorization", "Bearer " <> TE.encodeUtf8 apiKey)
                  ]
              }
        response <- httpLbs request manager
        if statusIsSuccessful (responseStatus response)
          then case decode (responseBody response) :: Maybe Value of
            Just (Object v) -> case parseMaybe (.: "data") v of
              Just (Array arr) -> case arr V.!? 0 of
                Just (Object item) -> case parseMaybe (.: "embedding") item of
                  Just emb -> return emb
                  Nothing  -> return []
                Nothing -> return []
              Nothing -> return []
            Nothing -> return []
          else return []

    , llmModels = return
        [ ModelInfo "deepseek-chat"     "DeepSeek Chat Model"     65536
        , ModelInfo "deepseek-reasoner" "DeepSeek Reasoner Model" 65536
        ]
    }
