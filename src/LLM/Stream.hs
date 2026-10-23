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
  , streamPostSse
  , openAICompatStreamCall
  ) where

import Control.Exception (try, SomeException)
import Control.Monad (join, when)
import Data.Aeson
import Data.Aeson.Key (fromText)
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseMaybe)
import Data.List (sortOn)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (HeaderName)
import Network.HTTP.Types.Status (statusCode)
import Data.Text.Encoding.Error (lenientDecode)

import LLM.Adapter.Types (Message(..), Role(..), ChatMessage, ChatTurn(..), StreamChunk(..), ToolCall(..), ToolSpec, Usage(..), mkUsage)

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

--------------------------------------------------------------------------------
-- Shared engine (A5): one SSE implementation for every OpenAI-compatible wire
--------------------------------------------------------------------------------

-- | A JSON object field.
fieldOf :: Text -> Object -> Maybe Value
fieldOf k o = KM.lookup (fromText k) o

-- | A JSON string field as plain text.
textOf :: Maybe Value -> Text
textOf (Just (String t)) = t
textOf _                 = ""

-- | POST a JSON body to an SSE endpoint and hand each @data:@ payload to the
-- callback the moment it arrives.  Never throws: failure comes back as @Left@.
streamPostSse
  :: String                            -- ^ endpoint URL
  -> [(HeaderName, BS.ByteString)]     -- ^ extra headers (auth, version, …)
  -> Value                             -- ^ request body
  -> (Value -> IO ())                  -- ^ per-frame callback
  -> IO (Either Text ())
streamPostSse url headers body onFrame = do
  mgr <- newManager tlsManagerSettings
  req0 <- parseRequest url
  let req = req0
        { method = "POST"
        , requestBody = RequestBodyLBS (encode body)
        , requestHeaders =
            ("Accept", "text/event-stream") : ("Content-Type", "application/json") : headers
        , responseTimeout = responseTimeoutNone
        }
  result <- try $ withResponse req mgr $ \resp -> do
    let code = statusCode (responseStatus resp)
    if code >= 400
      then do
        errBody <- brReadSome (responseBody resp) 4096
        return $ Left ("HTTP " <> T.pack (show code) <> ": " <> TE.decodeUtf8With lenientDecode (BSL.toStrict errBody))
      else do
        go (responseBody resp) ""
        return (Right ())
  case result of
    Left (ex :: SomeException) -> return $ Left (T.pack (show ex))
    Right r -> return r
  where
    go reader buf = do
      chunk <- brRead reader
      if BS.null chunk
        then pure ()
        else do
          let text = TE.decodeUtf8With lenientDecode chunk
              allFrames = buf <> text
              (frames, rest) = splitFrames allFrames
          mapM_ dispatch frames
          go reader rest
    splitFrames t = case T.breakOn "\n\n" t of
      (frame, rest) | T.null rest -> ([], frame)
                    | otherwise   -> let (f, r) = splitFrames (T.drop 2 rest) in (frame : f, r)
    dispatch frame = mapM_ oneLine (T.lines frame)
    oneLine line = case T.stripPrefix "data: " (T.strip line) of
      Just payload | payload /= "[DONE]" ->
        case decode (BSL.fromStrict (TE.encodeUtf8 payload)) of
          Just v  -> onFrame v
          Nothing -> pure ()
      _ -> pure ()

-- | Stream an OpenAI-compatible completion against any endpoint.  Each text
-- increment reaches @onEvent@ as it arrives; tool-call fragments are
-- aggregated per index and emitted once complete, so the returned @ChatTurn@
-- matches what the blocking call would have produced.
openAICompatStreamCall
  :: String                          -- ^ full endpoint URL
  -> Text                            -- ^ api key (empty = no Authorization header)
  -> Value                           -- ^ request body (caller sets @stream@)
  -> (StreamChunk -> IO ()) -> IO ChatTurn
openAICompatStreamCall url apiKey body onEvent = do
  acc <- newIORef []
  result <- streamPostSse url authHeaders body $ \v -> do
    case openAICompatDelta v of
      Just txt | not (T.null txt) -> onEvent (ChunkDelta txt)
      _                           -> pure ()
    calls <- readIORef acc
    writeIORef acc (foldl mergeCall calls (openAICompatToolDeltas v))
  done <- readIORef acc
  mapM_ (\(_, nm, args) -> onEvent (ChunkToolCall nm args))
        (sortOn (\(i, _, _) -> i) (reverse done))
  case result of
    Left e   -> do
      onEvent (ChunkError e)
      pure (ChatTurn "" [] Nothing (Just e))
    Right () -> do
      onEvent (ChunkDone (mkUsage 0 0 0))
      pure (ChatTurn "" [] Nothing Nothing)
  where
    authHeaders =
      [ ("Authorization", "Bearer " <> TE.encodeUtf8 apiKey) | not (T.null (T.strip apiKey)) ]

-- | Merge one tool-call fragment into the running list.  Fragments must be
-- appended (@new@ after @old@), never prepended — the provider sends the name
-- first and the arguments in pieces.
mergeCall :: [(Int, Text, Text)] -> (Int, Text, Text) -> [(Int, Text, Text)]
mergeCall acc (i, nm, ag) = case break (\(j, _, _) -> j == i) acc of
  (before, (_, nm0, ag0) : after) -> before ++ [(i, nm0 <> nm, ag0 <> ag)] ++ after
  _                               -> acc ++ [(i, nm, ag)]

-- | @choices[0].delta.content@ from a streaming frame.
openAICompatDelta :: Value -> Maybe Text
openAICompatDelta v = case v of
  Object o -> case fieldOf "choices" o of
    Just (Array a) -> case V.toList a of
      (Object c : _) -> case fieldOf "delta" c of
        Just (Object d) -> case fieldOf "content" d of
          Just (String t) -> Just t
          _               -> Nothing
        _ -> Nothing
      _ -> Nothing
    _ -> Nothing
  _ -> Nothing

-- | @choices[0].delta.tool_calls@ → (index, name chunk, argument chunk).
openAICompatToolDeltas :: Value -> [(Int, Text, Text)]
openAICompatToolDeltas v = case v of
  Object o -> case fieldOf "choices" o of
    Just (Array a) -> case V.toList a of
      (Object c : _) -> case fieldOf "delta" c of
        Just (Object d) -> case fieldOf "tool_calls" d of
          Just (Array tcs) -> [ (idx, nm, ag)
                              | Object tc <- V.toList tcs
                              , let idx = case fieldOf "index" tc of
                                            Just (Number n) -> round n
                                            _               -> 0
                              , let fn  = case fieldOf "function" tc of
                                            Just (Object f) -> f
                                            _               -> KM.empty
                              , let nm  = textOf (fieldOf "name" fn)
                              , let ag  = textOf (fieldOf "arguments" fn) ]
          _ -> []
        _ -> []
      _ -> []
    _ -> []
  _ -> []
