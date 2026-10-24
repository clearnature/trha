{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}

-- | DeepSeek API provider — real HTTP calls to DeepSeek's OpenAI-compatible API
module LLM.Providers.DeepSeek
  ( createDeepSeekProvider
  , buildDeepSeekChatRequest
  , parseDeepSeekChatTurn
  , applyEffortEnv
  , modelFromEnv
  , withReasoningEcho
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
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

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
  , ruCacheHitTokens   :: Int
  , ruCacheMissTokens  :: Int
  } deriving (Show, Generic)

instance FromJSON ChatResponse where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 2 }
instance FromJSON Choice where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 2 }
instance FromJSON RespMessage where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 2 }
-- Explicit on purpose: the cache fields are optional and live in two places
-- (flat @prompt_cache_*@ / nested @prompt_tokens_details.cached_tokens@), and
-- a generic instance would demand them all.
instance FromJSON RespUsage where
  parseJSON = withObject "usage" $ \o -> do
    p <- o .:? "prompt_tokens" .!= 0
    c <- o .:? "completion_tokens" .!= 0
    t <- o .:? "total_tokens" .!= (p + c)
    nested <- o .:? "prompt_tokens_details" >>= \case
      Just d  -> d .:? "cached_tokens" .!= 0
      Nothing -> pure 0
    hit <- o .:? "prompt_cache_hit_tokens" .!= nested
    miss <- o .:? "prompt_cache_miss_tokens" .!= max 0 (p - hit)
    pure $ RespUsage p c t hit miss
instance FromJSON RespToolCall where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 2 }
instance FromJSON RespToolFunction where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 2 }

-- | Thinking mode requires @reasoning_content@ back on *every* assistant turn,
-- including synthetic notes the host appends ("exhausted", "interrupted",
-- "[presentation]"). Attaching "" only where the chain is missing keeps the wire
-- valid without inventing reasoning.
withReasoningEcho :: [ChatMessage] -> [Value]
withReasoningEcho = map (addEcho . toJSON)
  where
    addEcho v = case v of
      Object o
        | Just (String "assistant") <- KM.lookup "role" o
        , not (KM.member "reasoning_content" o) ->
            Object (KM.insert "reasoning_content" (String "") o)
      _ -> v

-- | Build the OpenAI-compatible chat request body (with @tools@).
buildDeepSeekChatRequest :: Text -> [ChatMessage] -> [ToolSpec] -> Maybe GenParams -> Value
buildDeepSeekChatRequest model msgs specs genParams = object
  ( [ "model" .= model
    , "messages" .= withReasoningEcho msgs
    , "tools" .= specs
    , "stream" .= False
    ] ++ gpPairs )
  where
    gpPairs = case genParams of
      Nothing -> []
      Just gp -> [ "temperature" .= t | Just t <- [gpTemperature gp] ]
               ++ [ "max_tokens"  .= n | Just n <- [gpMaxTokens gp] ]

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
        [] -> return (ChatTurn "" [] Nothing (Just "no choices") Nothing)
        (c : _) -> do
          msg <- c .: "message"
          content <- msg .:? "content" .!= ""
          rawCalls <- msg .:? "tool_calls" .!= ([] :: [Value])
          calls <- mapM parseCall rawCalls
          usageV <- resp .:? "usage"
          usage <- traverse parseUsage usageV
          reasoning <- msg .:? "reasoning_content"
          return $ ChatTurn content calls usage Nothing reasoning
    parseCall = withObject "ToolCall" $ \o -> do
      fn <- o .: "function"
      args <- fn .: "arguments" >>= argsText
      ToolCall <$> o .: "id" <*> fn .: "name" <*> pure args
    -- OpenAI says @arguments@ is a JSON *string*, but some wires send the
    -- object itself; encode it back rather than failing the whole turn.
    argsText v = case v of
      String s -> pure s
      other    -> pure (TE.decodeUtf8 (BSL.toStrict (encode other)))
    parseUsage = withObject "usage" $ \o -> do
      p <- o .:? "prompt_tokens" .!= 0
      c <- o .:? "completion_tokens" .!= 0
      t <- o .:? "total_tokens" .!= (p + c)
      nested <- o .:? "prompt_tokens_details" >>= \case
        Just d  -> d .:? "cached_tokens" .!= 0
        Nothing -> pure 0
      hit <- o .:? "prompt_cache_hit_tokens" .!= nested
      miss <- o .:? "prompt_cache_miss_tokens" .!= max 0 (p - hit)
      pure $ Usage p c t hit miss

-- | Insert @reasoning_effort@ from the environment, when set.
--
-- deepseek-flash defaults to @high@, which spends reasoning tokens on every
-- call; the operator decides the cost/depth trade-off instead of the code
-- baking a level in.
-- | Ask for the final usage frame. Without it a streamed call reports nothing,
-- so cache hits and cost stay invisible on the streaming path.
withUsageFlag :: Value -> Value
withUsageFlag v = case v of
  Object o -> Object (KM.insert "stream_options" (object ["include_usage" .= True]) o)
  _        -> v

applyEffortEnv :: Value -> IO Value
applyEffortEnv v = do
  eff <- lookupEnv "TRHA_REASONING_EFFORT"
  cap <- lookupEnv "TRHA_MAX_OUTPUT_TOKENS"
  pure $ case v of
    Object o ->
      let o1 = maybe o (\e -> KM.insert "reasoning_effort" (String (T.pack e)) o) eff
          o2 = case (cap >>= readMaybe) :: Maybe Int of
                 Just n | n > 0, not (KM.member "max_tokens" o1) ->
                   KM.insert "max_tokens" (Number (fromIntegral n)) o1
                 _ -> o1
      in Object o2
    _ -> v

-- | The model id, overridable per deployment.
modelFromEnv :: IO Text
modelFromEnv = maybe "deepseek-flash" T.pack <$> lookupEnv "TRHA_LLM_MODEL"

-- | Create a DeepSeek provider with real API calls
createDeepSeekProvider :: Text -> IO LLMAdapter
createDeepSeekProvider apiKey = do
  manager <- newManager tlsManagerSettings
  model <- modelFromEnv
  let baseUrl = "https://api.deepseek.com"

  return $ LLMAdapter
    { llmChat = \messages -> do
        requestBody <- applyEffortEnv $ object
              [ "model"    .= model
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
                                     (ruCacheHitTokens u) (ruCacheMissTokens u)
                    Nothing -> mkUsage 0 0 0
              return [ChunkDelta content, ChunkDone usage]
            Nothing -> return [ChunkError "Failed to parse DeepSeek response"]
          else return [ChunkError $ "DeepSeek API error: " <> T.pack (show (statusCode (responseStatus response)))]

    , llmChatTools = \msgs specs gp -> deepSeekTools apiKey model manager msgs specs gp
    , llmChatToolsStream = deepSeekStream apiKey model

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
        [ ModelInfo "deepseek-flash"  "DeepSeek-V4.1-Flash"  524288
        , ModelInfo "deepseek-v4-pro" "DeepSeek-V4-Pro"      524288
        ]
    }

-- | Tool-calling call for the DeepSeek chat endpoint.  Shared by the blocking
-- and the streaming entry point so the two can never drift apart.
deepSeekTools :: Text -> Text -> Manager -> [ChatMessage] -> [ToolSpec] -> GenParams -> IO ChatTurn
deepSeekTools apiKey model manager msgs specs gp = do
  requestBody <- applyEffortEnv (buildDeepSeekChatRequest model msgs specs (Just gp))
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
        Left err -> return (ChatTurn "" [] Nothing (Just err) Nothing)
      Nothing -> return (ChatTurn "" [] Nothing (Just "Failed to parse DeepSeek response") Nothing)
    else return (ChatTurn "" [] Nothing (Just
      ("DeepSeek API error " <> T.pack (show (statusCode (responseStatus response)))
        <> ": " <> T.take 500 (TE.decodeUtf8 (BSL.toStrict (responseBody response))))) Nothing)

-- | Streaming tool-calling call: the very body the blocking path builds, fed
-- through the shared SSE engine, so increments reach the caller as produced
-- (tools included — no capability is lost by streaming).
deepSeekStream :: Text -> Text -> [ChatMessage] -> [ToolSpec] -> (StreamChunk -> IO ()) -> IO ChatTurn
deepSeekStream apiKey model msgs specs onEvent = do
  body <- applyEffortEnv (buildDeepSeekChatRequest model msgs specs Nothing)
  LStream.openAICompatStreamCall
    "https://api.deepseek.com/v1/chat/completions"
    apiKey
    (withUsageFlag (withStreamFlag body))
    onEvent
  where
    withStreamFlag v = case v of
      Object o -> Object (KM.insert "stream" (Bool True) o)
      other    -> other
