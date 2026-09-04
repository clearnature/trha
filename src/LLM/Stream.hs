{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Streaming HTTP client for LLM providers.
-- Uses http-client's withResponse for SSE (OpenAI/DeepSeek) and NDJSON (Anthropic).
module LLM.Stream
  ( StreamEvent(..)
  , StreamConfig(..)
  , StreamFormat(..)
  , streamChatCompletion
  , streamOpenAI
  , streamAnthropic
  , streamDeepSeek
  , parseSSELine
  , parseNDJSONLine
  ) where

import Control.Exception (try, SomeException)
import Control.Monad (when)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

import LLM.Adapter.Types (Message(..), Role(..))

data StreamEvent
  = SEVDelta Text
  | SEVToolCall Text Text
  | SEVUsage Int Int Int
  | SEVDone
  | SEVError Text
  deriving (Show, Eq)

data StreamConfig = StreamConfig
  { scUrl    :: String
  , scApiKey :: String
  , scBody   :: BSL.ByteString
  , scFormat :: StreamFormat
  }

data StreamFormat = SSEFormat | NDJSONFormat
  deriving (Show, Eq)

-- | Stream a chat completion with callback per event
streamChatCompletion :: StreamConfig -> (StreamEvent -> IO ()) -> IO (Either String ())
streamChatCompletion cfg onEvent = do
  mgr <- newManager tlsManagerSettings
  initialRequest <- parseRequest (scUrl cfg)
  let request = initialRequest
        { method = "POST"
        , requestBody = RequestBodyLBS (scBody cfg)
        , requestHeaders =
            [ ("Content-Type", "application/json")
            , ("Authorization", "Bearer " <> TE.encodeUtf8 (T.pack (scApiKey cfg)))
            , ("Accept", "text/event-stream")
            ]
        , responseTimeout = responseTimeoutNone
        }
  result <- try $ withResponse request mgr $ \response -> do
    let status = statusCode (responseStatus response)
    if status >= 400
      then do
        errBody <- brReadSome (responseBody response) 4096
        return $ Left $ "HTTP " ++ show status ++ ": " ++ show errBody
      else do
        let reader = responseBody response
        bufferRef <- newIORef BS.empty
        drainReader (scFormat cfg) onEvent reader bufferRef
        return (Right ())
  case result of
    Left (ex :: SomeException) -> return $ Left (show ex)
    Right r -> return r

-- | DeepSeek streaming (SSE, OpenAI-compatible)
streamDeepSeek :: String -> Text -> [Message] -> (StreamEvent -> IO ()) -> IO (Either String ())
streamDeepSeek apiKey model messages onEvent = do
  let body = object
        [ "model"    .= model
        , "messages" .= map toJSON messages
        , "stream"   .= True
        ]
  streamChatCompletion StreamConfig
    { scUrl    = "https://api.deepseek.com/v1/chat/completions"
    , scApiKey = apiKey
    , scBody   = encode body
    , scFormat = SSEFormat
    } onEvent

-- | OpenAI streaming (SSE)
streamOpenAI :: String -> Text -> [Message] -> (StreamEvent -> IO ()) -> IO (Either String ())
streamOpenAI apiKey model messages onEvent = do
  let body = object
        [ "model"    .= model
        , "messages" .= map toJSON messages
        , "stream"   .= True
        ]
  streamChatCompletion StreamConfig
    { scUrl    = "https://api.openai.com/v1/chat/completions"
    , scApiKey = apiKey
    , scBody   = encode body
    , scFormat = SSEFormat
    } onEvent

-- | Anthropic streaming (NDJSON)
streamAnthropic :: String -> Text -> [Message] -> (StreamEvent -> IO ()) -> IO (Either String ())
streamAnthropic apiKey model messages onEvent = do
  let body = object
        [ "model"      .= model
        , "messages"   .= map toAnthropicMsg messages
        , "max_tokens" .= (4096 :: Int)
        , "stream"     .= True
        ]
  streamChatCompletion StreamConfig
    { scUrl    = "https://api.anthropic.com/v1/messages"
    , scApiKey = apiKey
    , scBody   = encode body
    , scFormat = NDJSONFormat
    } onEvent
  where
    toAnthropicMsg m = object
      [ "role"    .= roleToText (messageRole m)
      , "content" .= messageContent m
      ]
    roleToText System    = "user" :: Text
    roleToText User      = "user"
    roleToText Assistant = "assistant"

-- Internal: chunked reader with line buffering
drainReader :: StreamFormat -> (StreamEvent -> IO ()) -> BodyReader -> IORef BS.ByteString -> IO ()
drainReader fmt onEvent reader bufferRef = do
  chunk <- brRead reader
  if BS.null chunk
    then do
      remainder <- readIORef bufferRef
      when (not $ BS.null remainder) $
        dispatchLine fmt onEvent remainder
    else do
      buffer <- readIORef bufferRef
      let combined = buffer <> chunk
      let (lines', remainder) = splitLines combined
      writeIORef bufferRef remainder
      mapM_ (dispatchLine fmt onEvent) lines'
      drainReader fmt onEvent reader bufferRef

splitLines :: BS.ByteString -> ([BS.ByteString], BS.ByteString)
splitLines bs = go bs []
  where
    go acc accLines =
      case BS.break (== 0x0A) acc of
        (line, rest)
          | BS.null rest -> (reverse accLines, line)
          | otherwise    -> go (BS.drop 1 rest) (line : accLines)

dispatchLine :: StreamFormat -> (StreamEvent -> IO ()) -> BS.ByteString -> IO ()
dispatchLine fmt onEvent line
  | BS.null line = return ()
  | otherwise = case fmt of
      SSEFormat    -> dispatchSSE onEvent line
      NDJSONFormat -> dispatchNDJSON onEvent line

-- SSE parser (OpenAI/DeepSeek)
dispatchSSE :: (StreamEvent -> IO ()) -> BS.ByteString -> IO ()
dispatchSSE onEvent line
  | "data: [DONE]" `BS.isPrefixOf` line = onEvent SEVDone
  | "data: " `BS.isPrefixOf` line =
      case eitherDecode (BSL.fromStrict (BS.drop 6 line)) of
        Right ev -> onEvent ev
        Left _   -> return ()
  | otherwise = return ()

parseSSELine :: BS.ByteString -> Maybe StreamEvent
parseSSELine line
  | "data: [DONE]" `BS.isPrefixOf` line = Just SEVDone
  | "data: " `BS.isPrefixOf` line = case eitherDecode (BSL.fromStrict (BS.drop 6 line)) of
      Right ev -> Just ev
      Left _   -> Nothing
  | otherwise = Nothing

instance FromJSON StreamEvent where
  parseJSON = withObject "StreamEvent" $ \v -> do
    choices <- v .:? "choices" .!= ([] :: [Value])
    case choices of
      [] -> do
        err <- v .:? "error"
        case err of
          Just (Object e) -> SEVError <$> e .:? "message" .!= "Unknown error"
          _ -> do
            usage <- v .:? "usage"
            case usage of
              Just (Object u) -> do
                pt <- u .:? "prompt_tokens" .!= 0
                ct <- u .:? "completion_tokens" .!= 0
                tt <- u .:? "total_tokens" .!= 0
                pure (SEVUsage pt ct tt)
              _ -> pure SEVDone
      (c:_) -> withObject "Choice" (\cv -> do
        delta <- cv .:? "delta"
        finish <- cv .:? "finish_reason"
        case delta of
          Just (Object d) -> do
            content <- d .:? "content"
            case content of
              Just (String t) -> pure (SEVDelta t)
              Nothing -> do
                toolCalls <- d .:? "tool_calls"
                case toolCalls of
                  Just (Array arr) | not (V.null arr) -> do
                    let first = V.head arr
                    case first of
                      Object tcObj -> do
                        fn <- tcObj .:? "function"
                        case fn of
                          Just (Object f) -> do
                            name <- f .:? "name" .!= ""
                            args <- f .:? "arguments" .!= ""
                            pure (SEVToolCall name args)
                          _ -> pure (SEVDelta "")
                      _ -> pure (SEVDelta "")
                  _ -> pure (SEVDelta "")
          Nothing -> case finish of
            Just (String "stop") -> pure SEVDone
            Just (String "tool_calls") -> pure SEVDone
            _ -> pure (SEVDelta "")) c

-- NDJSON parser (Anthropic)
dispatchNDJSON :: (StreamEvent -> IO ()) -> BS.ByteString -> IO ()
dispatchNDJSON onEvent line =
  case eitherDecode (BSL.fromStrict line) of
    Right ev -> onEvent ev
    Left _   -> return ()

parseNDJSONLine :: BS.ByteString -> Maybe StreamEvent
parseNDJSONLine bs = case eitherDecode (BSL.fromStrict bs) of
  Right ev -> Just ev
  Left _   -> Nothing

-- Anthropic event parser (separate from OpenAI)
parseAnthropicEvent :: Value -> Maybe StreamEvent
parseAnthropicEvent = parseMaybe $ withObject "AnthropicEvent" $ \v -> do
  typ <- v .:? "type" .!= ("" :: Text)
  case typ of
    "content_block_delta" -> do
      deltaObj <- v .: "delta"
      case deltaObj of
        Object d -> do
          deltaType <- d .:? "type" .!= ("" :: Text)
          if deltaType == "text_delta"
            then SEVDelta <$> d .: "text"
            else pure (SEVDelta "")
        _ -> pure (SEVDelta "")
    "message_stop" -> pure SEVDone
    "error" -> do
      errObj <- v .:? "error"
      case errObj of
        Just (Object e) -> SEVError <$> e .:? "message" .!= "Unknown error"
        _ -> pure (SEVError "Unknown error")
    "ping" -> pure (SEVDelta "")
    _ -> pure (SEVDelta "")
