{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

-- | DeepSeek API provider — real HTTP calls to DeepSeek's OpenAI-compatible API
module LLM.Providers.DeepSeek
  ( createDeepSeekProvider
  , buildDeepSeekChatRequest
  , parseDeepSeekChatTurn
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
import qualified LLM.Stream as LStream
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseEither, parseMaybe, withObject, (.:), (.:?), (.!=))

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
  { rmRole      :: Text
  , rmContent   :: Text
  , rmToolCalls :: Maybe [RespToolCall]
  } deriving (Show, Generic)

data RespToolCall = RespToolCall
  { rtId       :: Text
  , rtType     :: Text
  , rtFunction :: RespToolFunction
  } deriving (Show, Generic)

data RespToolFunction = RespToolFunction
  { rtfName      :: Text
  , rtfArguments :: Text
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
instance FromJSON RespToolCall where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 2 }
instance FromJSON RespToolFunction where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 2 }

-- | Build the OpenAI-compatible chat request body (with @tools@).
buildDeepSeekChatRequest :: Text -> [ChatMessage] -> [ToolSpec] -> Value
buildDeepSeekChatRequest model msgs specs = object
  [ "model" .= model
  , "messages" .= msgs
  , "tools" .= specs
  , "stream" .= False
  ]

-- | Parse a chat completion response into a 'ChatTurn' (content + tool
-- calls + usage).
parseDeepSeekChatTurn :: Value -> Either Text ChatTurn
parseDeepSeekChatTurn v =
  case parseEither go v of
    Left err  -> Left (T.pack err)
    Right t   -> Right t
  where
    go = withObject "ChatResponse" $ \resp -> do
      choices <- resp .: "choices"
      case choices of
        [] -> return (ChatTurn "" [] Nothing (Just "no choices"))
        (c : _) -> do
          msg <- c .: "message"
          content <- msg .:? "content" .!= ""
          rawCalls <- msg .:? "tool_calls" .!= ([] :: [Value])
          calls <- mapM parseCall rawCalls
          usageV <- resp .:? "usage"
          usage <- traverse parseUsage usageV
          return $ ChatTurn content calls usage Nothing
    parseCall = withObject "ToolCall" $ \o -> do
      fn <- o .: "function"
      ToolCall <$> o .: "id" <*> fn .: "name" <*> fn .: "arguments"
    parseUsage = withObject "usage" $ \o -> Usage
      <$> o .:? "prompt_tokens" .!= 0
      <*> o .:? "completion_tokens" .!= 0
      <*> o .:? "total_tokens" .!= 0

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

    , llmChatTools = deepSeekTools apiKey manager
    , llmChatToolsStream = deepSeekStream apiKey

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

-- | Tool-calling call for the DeepSeek chat endpoint.  Shared by the blocking
-- and the streaming entry point so the two can never drift apart.
deepSeekTools :: Text -> Manager -> [ChatMessage] -> [ToolSpec] -> IO ChatTurn
deepSeekTools apiKey manager msgs specs = do
  let requestBody = buildDeepSeekChatRequest "deepseek-chat" msgs specs
  initialRequest <- parseRequest ("https://api.deepseek.com/v1/chat/completions")
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
      Just v -> case parseDeepSeekChatTurn v of
        Right turn -> return turn
        Left err -> return (ChatTurn "" [] Nothing (Just err))
      Nothing -> return (ChatTurn "" [] Nothing (Just "Failed to parse DeepSeek response"))
    else return (ChatTurn "" [] Nothing (Just ("DeepSeek API error: " <> T.pack (show (statusCode (responseStatus response))))))

-- | Streaming tool-calling call: the very body the blocking path builds, fed
-- through the shared SSE engine, so increments reach the caller as produced
-- (tools included — no capability is lost by streaming).
deepSeekStream :: Text -> [ChatMessage] -> [ToolSpec] -> (StreamChunk -> IO ()) -> IO ChatTurn
deepSeekStream apiKey msgs specs onEvent =
  LStream.openAICompatStreamCall
    "https://api.deepseek.com/v1/chat/completions"
    apiKey
    (withStreamFlag (buildDeepSeekChatRequest "deepseek-chat" msgs specs))
    onEvent
  where
    withStreamFlag v = case v of
      Object o -> Object (KM.insert "stream" (Bool True) o)
      other    -> other
