{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

-- | OpenAI API provider — real HTTP calls to OpenAI's API
module LLM.Providers.OpenAI
  ( createOpenAIProvider
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

import LLM.Adapter.Interface (LLMAdapter(..), unsupportedTools)
import qualified LLM.Stream as LStream

-- | OpenAI API response types
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

-- | Create an OpenAI provider with real API calls
createOpenAIProvider :: Text -> IO LLMAdapter
createOpenAIProvider apiKey = do
  manager <- newManager tlsManagerSettings
  let baseUrl = "https://api.openai.com"

  return $ LLMAdapter
    { llmChat = \messages -> do
        let requestBody = object
              [ "model"    .= ("gpt-4" :: Text)
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
            Nothing -> return [ChunkError "Failed to parse OpenAI response"]
          else return [ChunkError $ "OpenAI API error: " <> T.pack (show (statusCode (responseStatus response)))]

    , llmChatTools = \msgs specs _gp -> unsupportedTools msgs specs
    , llmChatToolsStream = openAIStream apiKey
    , llmEmbed = \text -> do
        let requestBody = object
              [ "model" .= ("text-embedding-ada-002" :: Text)
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
        [ ModelInfo "gpt-4"       "GPT-4 Model"       8192
        , ModelInfo "gpt-4-turbo" "GPT-4 Turbo Model" 128000
        , ModelInfo "gpt-3.5-turbo" "GPT-3.5 Turbo"   16385
        ]
    }

-- | Streaming call.  Text only, matching this adapter's declared capability
-- (@unsupportedTools@): streaming must not quietly claim more than blocking.
openAIStream :: Text -> [ChatMessage] -> [ToolSpec] -> (StreamChunk -> IO ()) -> IO ChatTurn
openAIStream apiKey msgs _specs onEvent =
  LStream.openAICompatStreamCall
    "https://api.openai.com/v1/chat/completions"
    apiKey
    (object [ "model"    .= ("gpt-4" :: Text)
            , "messages" .= map toJSON msgs
            , "stream"   .= True ])
    onEvent
