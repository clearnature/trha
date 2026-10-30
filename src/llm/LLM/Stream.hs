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
  , streamTimeoutMs
  , streamFirstByteTimeoutMs
  ) where

import Control.Exception (try, SomeException)
import Control.Monad (join, when)
import Data.Aeson
import Data.Aeson.Key (fromText)
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseMaybe)
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Core.HTTPProxy
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (Header, HeaderName)
import Network.HTTP.Types.Status (statusCode)
import Data.Text.Encoding.Error (lenientDecode)
import System.Environment (lookupEnv)
import System.Timeout (timeout)
import Text.Read (readMaybe)

import LLM.Adapter.Types (Message(..), Role(..), ChatMessage, ChatTurn(..), StreamChunk(..), ToolCall(..), ToolSpec, Usage(..), mkUsage)

data StreamEvent
  = SEVDelta Text
  | SEVReasoning Text        -- ^ thinking-mode delta (echoed back on tool turns)
  | SEVReasoningSignature Text -- ^ thinking-block signature (Anthropic wire)
  | SEVToolCall Text Text
  | SEVToolCallAt Int Text Text Text   -- ^ index, id, name, args
  | SEVUsage Int Int Int
  | SEVUsageFull Usage       -- ^ same numbers, with cache accounting
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
  idleMs <- streamTimeoutMs
  firstMs <- streamFirstByteTimeoutMs
  mgr <- newManager =<< proxyAwareSettings (scUrl cfg) tlsManagerSettings
  initialRequest <- parseRequest (scUrl cfg)
  let request = initialRequest
        { method = "POST"
        , requestBody = RequestBodyLBS (scBody cfg)
        , requestHeaders =
            [ ("Content-Type", "application/json")
            , ("Authorization", "Bearer " <> TE.encodeUtf8 (T.pack (scApiKey cfg)))
            , ("Accept", "text/event-stream")
            ]
        -- Covers the wait for response *headers*: with a big context the
        -- provider may not even send headers until it has a first token.
        -- NB: responseTimeoutMicro takes **microseconds**, firstMs is ms.
        , responseTimeout = responseTimeoutMicro (firstMs * 1000)
        }
  stalledRef <- newIORef (Nothing :: Maybe Text)
  -- Outer budget is only a backstop against "always trickling, never ending";
  -- the per-read budgets below fire first for a dead provider.
  let totalMs = idleMs * 60
  result <- try $ timeout (totalMs * 1000) $ withResponse request mgr $ \response -> do
    let status = statusCode (responseStatus response)
    if status >= 400
      then do
        errBody <- brReadSome (responseBody response) 4096
        return $ Left $ "HTTP " ++ show status ++ ": " ++ show errBody
      else do
        let reader = responseBody response
        bufferRef <- newIORef BS.empty
        drainReader firstMs idleMs (scFormat cfg) onEvent reader bufferRef stalledRef
        return (Right ())
  stalled <- readIORef stalledRef
  case result of
    Left (ex :: SomeException) -> return $ Left (T.unpack (renderStreamError firstMs ex))
    Right Nothing -> return $ Left ("stream timed out after " <> show totalMs <> " ms (total budget)")
    Right (Just r) -> return $ case stalled of
      Just "first-byte" -> Left ("stream timed out: no first byte within " <> show firstMs <> " ms")
      Just _ -> Left ("stream timed out: no data for " <> show idleMs <> " ms mid-stream")
      Nothing -> r

-- | How long a stream may stay silent *after the first byte* before it is
-- abandoned.
--
-- Enforced *per read* (`drainReader` / `streamPostSse`'s `go`): a slow but
-- live answer may legitimately take minutes, while silence for this long means
-- the provider is gone. The outer budget is only a backstop (@ms * 60@), so a
-- long generation is never cut short just for being long.
--
-- The wait for the *first* byte uses the larger
-- 'streamFirstByteTimeoutMs' budget instead (provider queuing, prompt
-- processing, large-context upload).  @responseTimeoutNone@ means a stalled
-- provider would otherwise hang the whole step forever, which is why these
-- bounds exist at all. Overridable for tests and slow deployments
-- (@TRHA_STREAM_TIMEOUT_MS@).
streamTimeoutMs :: IO Int
streamTimeoutMs = envMs "TRHA_STREAM_TIMEOUT_MS" 45000

-- | http-client reports the header wait as a @ResponseTimeout@ exception;
-- spell it out instead of leaking the constructor to the TUI.
renderStreamError :: Int -> SomeException -> Text
renderStreamError firstMs ex
  | "ResponseTimeout" `T.isInfixOf` T.pack (show ex) =
      "stream timed out: no response headers within " <> T.pack (show firstMs) <> " ms"
  | otherwise = T.pack (show ex)

-- | How long the *first* byte may take.
--
-- Waiting for the first token covers provider queuing, prompt processing and
-- uploading a large context, so it is a different failure from mid-stream
-- silence and gets a larger budget.  With one shared 20 s budget, a large
-- session could time out before the provider said anything at all (observed:
-- "stream timed out" on a long turn, with no partial output to rescue).
streamFirstByteTimeoutMs :: IO Int
streamFirstByteTimeoutMs = envMs "TRHA_STREAM_FIRST_BYTE_TIMEOUT_MS" 90000

-- | Positive milliseconds from an environment variable, else the default.
envMs :: String -> Int -> IO Int
envMs name dflt = do
  raw <- lookupEnv name
  pure $ case raw >>= readMaybe of
    Just n | n > 0 -> n
    _              -> dflt

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
drainReader :: Int -> Int -> StreamFormat -> (StreamEvent -> IO ()) -> BodyReader -> IORef BS.ByteString -> IORef (Maybe Text) -> IO ()
drainReader firstMs idleMs fmt onEvent reader bufferRef stalledRef = go True
  where
    -- Two budgets, because "the provider is still thinking" and "the provider
    -- is gone" are different failures.  The first byte has to wait for
    -- queuing, prompt processing and upload of a large context; after that,
    -- silence for `idleMs` means the connection is dead.
    go isFirst = do
      let budget = if isFirst then firstMs else idleMs
      next <- timeout (budget * 1000) (brRead reader)
      case next of
        Nothing -> writeIORef stalledRef (Just (if isFirst then "first-byte" else "idle"))
        Just chunk
          | BS.null chunk -> do
              remainder <- readIORef bufferRef
              when (not $ BS.null remainder) $
                dispatchLine fmt onEvent remainder
          | otherwise -> do
              buffer <- readIORef bufferRef
              let combined = buffer <> chunk
              let (lines', remainder) = splitLines combined
              writeIORef bufferRef remainder
              mapM_ (dispatchLine fmt onEvent) lines'
              go False

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
  idleMs <- streamTimeoutMs
  firstMs <- streamFirstByteTimeoutMs
  mgr <- newManager =<< proxyAwareSettings url tlsManagerSettings
  req0 <- parseRequest url
  let req = req0
        { method = "POST"
        , requestBody = RequestBodyLBS (encode body)
        , requestHeaders =
            ("Accept", "text/event-stream") : ("Content-Type", "application/json") : headers
        -- Header wait counts against the first-byte budget (see above).
        -- Microseconds again: firstMs is in ms.
        , responseTimeout = responseTimeoutMicro (firstMs * 1000)
        }
  stalledRef <- newIORef (Nothing :: Maybe Text)
  let totalMs = idleMs * 60
  result <- try $ timeout (totalMs * 1000) $ withResponse req mgr $ \resp -> do
    let code = statusCode (responseStatus resp)
    if code >= 400
      then do
        errBody <- brReadSome (responseBody resp) 4096
        return $ Left ("HTTP " <> T.pack (show code) <> ": " <> TE.decodeUtf8With lenientDecode (BSL.toStrict errBody))
      else do
        go firstMs idleMs stalledRef (responseBody resp) "" True
        return (Right ())
  stalled <- readIORef stalledRef
  case result of
    Left (ex :: SomeException) -> return $ Left (renderStreamError firstMs ex)
    Right Nothing -> return $ Left (T.pack ("stream timed out after " <> show totalMs <> " ms (total budget)"))
    Right (Just r) -> return $ case stalled of
      Just "first-byte" -> Left (T.pack ("stream timed out: no first byte within " <> show firstMs <> " ms"))
      Just _ -> Left (T.pack ("stream timed out: no data for " <> show idleMs <> " ms mid-stream"))
      Nothing -> r
  where
    -- Two budgets, mirroring drainReader: the wait for the first byte includes
    -- provider queuing and prompt processing, so it gets a larger allowance
    -- than mid-stream silence.
    go firstMs idleMs stalled reader buf isFirst = do
      let budget = if isFirst then firstMs else idleMs
      next <- timeout (budget * 1000) (brRead reader)
      case next of
        Nothing -> writeIORef stalled (Just (if isFirst then "first-byte" else "idle"))
        Just chunk
          | BS.null chunk -> pure ()
          | otherwise -> do
              let text = TE.decodeUtf8With lenientDecode chunk
                  allFrames = buf <> text
                  (frames, rest) = splitFrames allFrames
              mapM_ dispatch frames
              go firstMs idleMs stalled reader rest False
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
  -> [Header]                        -- ^ request headers (Authorization included by caller)
  -> Value                           -- ^ request body (caller sets @stream@)
  -> (StreamChunk -> IO ()) -> IO ChatTurn
openAICompatStreamCall url headers body onEvent = do
  acc <- newIORef ([] :: [(Int, Text, Text, Text)])
  textRef <- newIORef []
  reasonRef <- newIORef []
  usageRef <- newIORef Nothing
  result <- streamPostSse url headers body $ \v -> do
    case openAICompatDelta v of
      Just txt | not (T.null txt) -> do
        modifyIORef' textRef (txt :)
        onEvent (ChunkDelta txt)
      _ -> pure ()
    case openAICompatReasoning v of
      Just r | not (T.null r) -> do
        modifyIORef' reasonRef (r :)
        onEvent (ChunkReasoning r)
      _ -> pure ()
    case openAICompatUsage v of
      Just u  -> writeIORef usageRef (Just u)
      Nothing -> pure ()
    calls <- readIORef acc
    writeIORef acc (foldl mergeCall calls (openAICompatToolDeltas v))
  done <- readIORef acc
  mapM_ (\(i, id0, nm, args) -> onEvent (ChunkToolCallAt i id0 nm args))
        (sortOn (\(i, _, _, _) -> i) (reverse done))
  txt <- T.concat . reverse <$> readIORef textRef
  reason <- readIORef reasonRef
  usage <- readIORef usageRef
  let reasoning = case T.concat (reverse reason) of
        "" -> Nothing
        r  -> Just r
      turn = ChatTurn txt
               [ ToolCall (if T.null id0 then "call-" <> T.pack (show i) else id0) nm args
               | (i, id0, nm, args) <- sortOn (\(i, _, _, _) -> i) (reverse done) ]
               usage Nothing reasoning Nothing
  case result of
    Left e -> do
      onEvent (ChunkError e)
      -- Keep what already arrived: a timeout after three tokens is a partial
      -- answer with a reason, not an empty one. Tool calls are dropped — a
      -- half-streamed call would be malformed.
      pure (ChatTurn txt [] usage (Just e) reasoning Nothing)
    Right () -> do
      onEvent (ChunkDone (fromMaybe (mkUsage 0 0 0) usage))
      pure turn
  where

-- | Merge one tool-call fragment into the running list.  Fragments must be
-- appended (@new@ after @old@), never prepended — the provider sends the name
-- first and the arguments in pieces.
mergeCall :: [(Int, Text, Text, Text)] -> (Int, Text, Text, Text) -> [(Int, Text, Text, Text)]
mergeCall acc (i, id0, nm, ag) = case break (\(j, _, _, _) -> j == i) acc of
  (before, (_, id1, nm0, ag0) : after) ->
    before ++ [(i, if T.null id1 then id0 else id1, nm0 <> nm, ag0 <> ag)] ++ after
  _ -> acc ++ [(i, id0, nm, ag)]

-- | @choices[0].delta.reasoning_content@ from a streaming frame.
openAICompatReasoning :: Value -> Maybe Text
openAICompatReasoning v = case v of
  Object o -> case fieldOf "choices" o of
    Just (Array a) -> case V.toList a of
      (Object c : _) -> case fieldOf "delta" c of
        Just (Object d) -> case fieldOf "reasoning_content" d of
          Just (String t) -> Just t
          _               -> Nothing
        _ -> Nothing
      _ -> Nothing
    _ -> Nothing
  _ -> Nothing

-- | The usage frame: OpenAI-compatible streams send it last when asked with
-- @stream_options.include_usage@; DeepSeek adds the cache split.
openAICompatUsage :: Value -> Maybe Usage
openAICompatUsage v = case v of
  Object o -> case fieldOf "usage" o of
    Just u  -> parseMaybe parseJSON u
    Nothing -> Nothing
  _ -> Nothing

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
openAICompatToolDeltas :: Value -> [(Int, Text, Text, Text)]
openAICompatToolDeltas v = case v of
  Object o -> case fieldOf "choices" o of
    Just (Array a) -> case V.toList a of
      (Object c : _) -> case fieldOf "delta" c of
        Just (Object d) -> case fieldOf "tool_calls" d of
          Just (Array tcs) -> [ (idx, id0, nm, ag)
                              | Object tc <- V.toList tcs
                              , let idx = case fieldOf "index" tc of
                                            Just (Number n) -> round n
                                            _               -> 0
                              , let id0 = textOf (fieldOf "id" tc)
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
