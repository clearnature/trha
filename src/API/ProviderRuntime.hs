{-# LANGUAGE OverloadedStrings #-}

-- | Provider runtime: build an LLM adapter for a saved provider.
--
-- All three wires the kernel declares are implemented — the OpenAI-compatible
-- chat wire, Anthropic's Messages wire and OpenAI's Responses wire — following
-- the reference implementation's field choices (`internal/provider/anthropic`,
-- `internal/provider/responses`).  A provider whose kind is unknown still says
-- so instead of failing at call time.
module API.ProviderRuntime
  ( adapterFor
  , openAICompatAdapter
  , anthropicAdapter
  , responsesAdapter
  , providerStream
  , openAICompatStream
  , anthropicStream
  , responsesStream
  , cpuAdapterFor
  , cpuAdapterCacheSize
  , StreamCall
  ) where

import Control.Concurrent.MVar (MVar, newMVar, modifyMVar, withMVar)
import Data.Aeson (Object, Value(..), decode, encode, object, toJSON, (.=))
import Data.Aeson.Key (fromText)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import qualified Data.Vector as V
import Data.IORef (IORef, newIORef, readIORef, writeIORef, modifyIORef')
import qualified Data.ByteString as BS
import qualified Data.Map as Map
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (statusCode, statusIsSuccessful)
import System.IO.Unsafe (unsafePerformIO)

import Core.Provider.Types
import LLM.Adapter.Interface (LLMAdapter(..), StreamCall, createCPUAdapterWith)
import qualified LLM.Stream as LStream
import LLM.Adapter.Types
import LLM.Providers.DeepSeek (buildDeepSeekChatRequest, parseDeepSeekChatTurn)
import Infrastructure.CPU.InferenceGPU (gpuForwardFactory)
import System.Environment (lookupEnv)

--------------------------------------------------------------------------------
-- Local inference backend ("cpu" kind)
--------------------------------------------------------------------------------

-- | Local-inference adapters, cached **by model path**.
--
-- @createCPUAdapter@ calls @loadModel@ on every invocation (a local .sov/GGUF
-- can be hundreds of MB), so building one per request would be unusable.  The
-- adapter closes over its engine, so caching the adapter caches the engine.
{-# NOINLINE cpuAdapterCache #-}
cpuAdapterCache :: MVar (Map.Map FilePath LLMAdapter)
cpuAdapterCache = unsafePerformIO (newMVar Map.empty)

-- | Get (or build) the local-inference adapter for a model path.
cpuAdapterFor :: FilePath -> IO LLMAdapter
cpuAdapterFor path = modifyMVar cpuAdapterCache $ \m ->
  case Map.lookup path m of
    Just a  -> pure (m, a)
    Nothing -> do
      -- TRHA_GPU=1：尝试挂 WebGPU 前端（60 层 matmul 上 GPU；失败回退 CPU，不崩）
      gpuOn <- maybe False (== "1") <$> lookupEnv "TRHA_GPU"
      if not gpuOn
        then do
          (_, a0) <- createCPUAdapterWith Nothing path
          pure (Map.insert path a0 m, a0)
        else do
          gpuF <- gpuForwardFactory path 12
          case gpuF of
            Left err -> do
              putStrLn ("[gpu] 未启用 WebGPU 前端（回退 CPU）: " ++ err)
              (_, a0) <- createCPUAdapterWith Nothing path
              pure (Map.insert path a0 m, a0)
            Right fwd -> do
              (_, a') <- createCPUAdapterWith (Just fwd) path
              pure (Map.insert path a' m, a')

-- | Number of cached local adapters (lets tests assert path reuse).
cpuAdapterCacheSize :: IO Int
cpuAdapterCacheSize = withMVar cpuAdapterCache (pure . Map.size)

-- | Build an adapter for a saved provider entry, given its key.
--
-- @"cpu"@ is the in-kernel local inference backend: no key, no network — for
-- this kind @peBaseUrl@ carries the **model path**.
adapterFor :: ProviderEntry -> Text -> IO (Either Text LLMAdapter)
adapterFor entry key = case peKind entry of
  "openai"    -> Right <$> openAICompatAdapter (peBaseUrl entry) key (peDefault entry)
  "anthropic" -> Right <$> anthropicAdapter (peBaseUrl entry) key (peDefault entry)
  "responses" -> Right <$> responsesAdapter (peBaseUrl entry) key (peDefault entry)
  "cpu"       -> Right <$> cpuAdapterFor (T.unpack (T.strip (peBaseUrl entry)))
  other       -> pure (Left ("provider kind not implemented yet: " <> other))

--------------------------------------------------------------------------------
-- Shared bits
--------------------------------------------------------------------------------

-- | The endpoint root: "@…\/v1@" is dropped, because each wire appends its own
-- path ("\/v1\/messages", "\/v1\/responses") and "@…\/v1\/v1\/messages@" 404s.
rootOf :: Text -> Text
rootOf u =
  let t = T.dropWhileEnd (== '/') (T.strip u)
  in if "/v1" `T.isSuffixOf` t then T.dropEnd 3 t else t

-- | Render a JSON value back to the text form tool arguments travel in.
jsonText :: Value -> Text
jsonText v = TE.decodeUtf8 (BL.toStrict (encode v))

-- | Look a field up in an Aeson object (Prelude.lookup does not apply here).
field :: Text -> Object -> Maybe Value
field k o = KM.lookup (fromText k) o

-- | A non-streaming call: POST and hand back (status, body, ok).
postJson :: Manager -> String -> [Header] -> Value -> IO (Int, BL.ByteString, Bool)
postJson manager url headers body = do
  req0 <- parseRequest url
  let req = req0
        { method = "POST"
        , requestBody = RequestBodyLBS (encode body)
        , requestHeaders = headers
        }
  resp <- httpLbs req manager
  pure (statusCode (responseStatus resp), responseBody resp, statusIsSuccessful (responseStatus resp))

bearer :: Text -> [Header]
bearer k
  | T.null (T.strip k) = []
  | otherwise = [("Authorization", "Bearer " <> TE.encodeUtf8 k)]

usageOf :: Maybe Int -> Maybe Int -> Usage
usageOf mi mo = mkUsage (fromMaybe 0 mi) (fromMaybe 0 mo) (fromMaybe 0 mi + fromMaybe 0 mo)

--------------------------------------------------------------------------------
-- Streaming (A2): the wire decides, not the adapter
--------------------------------------------------------------------------------

-- | A streaming caller for a saved provider.  A wire without a streaming path
-- falls back to the blocking adapter and emits its answer as one delta, so
-- callers always receive events.
providerStream :: ProviderEntry -> Text -> IO StreamCall
providerStream entry key = case peKind entry of
  "openai"    -> openAICompatStream (peBaseUrl entry) key (peDefault entry)
  "anthropic" -> anthropicStream (peBaseUrl entry) key (peDefault entry)
  "responses" -> responsesStream (peBaseUrl entry) key (peDefault entry)
  -- 本地推理 backend：走**真实流式**（cpuStream 逐 token 回调），
  -- 不落到下面的 blockingStream 回退。
  "cpu"       -> do
    a <- cpuAdapterFor (T.unpack (T.strip (peBaseUrl entry)))
    pure (llmChatToolsStream a)
  _        -> do
    built <- adapterFor entry key
    pure $ case built of
      Right a   -> blockingStream a
      Left why  -> \_ _ onEvent -> do
        onEvent (ChunkError why)
        pure (ChatTurn "" [] Nothing (Just why) Nothing)
  where
    -- The blocking call, announced as one delta: a wire with no streaming
    -- path still gives the caller events it can forward.
    blockingStream a msgs specs onEvent = do
      turn <- llmChatTools a msgs specs defaultGenParams
      onEvent (ChunkDelta (ctContent turn))
      onEvent (ChunkDone (maybe (mkUsage 0 0 0) id (ctUsage turn)))
      pure turn

-- | An OpenAI-compatible streaming caller.  The SSE transport and the
-- tool-call aggregation live in LLM.Stream, so every OpenAI-compatible wire —
-- saved providers and the DeepSeek/OpenAI adapters alike — shares one engine.
openAICompatStream :: Text -> Text -> Text -> IO StreamCall
openAICompatStream baseUrl apiKey model =
  pure $ \msgs specs onEvent -> do
    let base = buildDeepSeekChatRequest model msgs specs Nothing
        body = case base of
          Object o -> Object (KM.insert "stream" (Bool True) o)
          other    -> other
    LStream.openAICompatStreamCall
      (T.unpack (T.dropWhileEnd (== '/') (T.strip baseUrl)) ++ "/chat/completions")
      apiKey body onEvent

-- | The Messages API body, shared by the blocking and the streaming caller.
anthropicRequestBody :: Text -> [ChatMessage] -> [ToolSpec] -> Value
anthropicRequestBody model msgs specs =
  let (systemText, turns) = toAnthropicMessages msgs
  in object $
       [ "model"      .= model
       , "max_tokens" .= (4096 :: Int)
       , "messages"   .= turns
       ] ++ [ "system" .= systemText | not (T.null systemText) ]
         ++ [ "tools"  .= map anthropicTool specs | not (null specs) ]

-- | The Responses API body, shared by the blocking and the streaming caller.
responsesRequestBody :: Text -> [ChatMessage] -> [ToolSpec] -> Bool -> Value
responsesRequestBody model msgs specs streaming =
  let (instructions, items) = toResponsesInput msgs
  in object $
       [ "model" .= model, "input" .= items, "stream" .= streaming ]
       ++ [ "instructions" .= instructions | not (T.null instructions) ]
       ++ [ "tools" .= map responsesTool specs | not (null specs) ]

-- | Anthropic's streaming caller: SSE with named events.
anthropicStream :: Text -> Text -> Text -> IO StreamCall
anthropicStream baseUrl apiKey model = do
  let url = T.unpack (rootOf baseUrl) ++ "/v1/messages"
      headers = [ ("Content-Type", "application/json")
                , ("anthropic-version", "2023-06-01") ]
                ++ [("x-api-key", TE.encodeUtf8 apiKey) | not (T.null (T.strip apiKey))]
  pure $ \msgs specs onEvent -> do
    pending <- newIORef (Nothing :: Maybe (Text, Text))
    result <- LStream.streamPostSse url headers (anthropicRequestBody model msgs specs) $ \v -> do
      case anthropicEvent v of
        Just (Left txt) -> onEvent (ChunkDelta txt)
        Just (Right u)  -> onEvent (ChunkDone u)
        Nothing         -> pure ()
      done <- anthropicToolStep pending v
      mapM_ (\(nm, args) -> onEvent (ChunkToolCall nm args)) done
    case result of
      Left e   -> do onEvent (ChunkError e); pure (ChatTurn "" [] Nothing (Just e) Nothing)
      Right () -> pure (ChatTurn "" [] Nothing Nothing Nothing)

-- | @content_block_delta.delta.text@ is a text increment; @message_delta@
-- closes the run and carries its usage.
anthropicEvent :: Value -> Maybe (Either Text Usage)
anthropicEvent v = case v of
  Object o -> case field "type" o of
    Just (String "content_block_delta") -> case field "delta" o of
      Just (Object d) -> case field "text" d of
        Just (String t) -> Just (Left t)
        _               -> Nothing
      _ -> Nothing
    Just (String "message_delta") -> case field "usage" o of
      Just (Object u) -> Just (Right (usageOf (jsonInt "input_tokens" u) (jsonInt "output_tokens" u)))
      _               -> Nothing
    _ -> Nothing
  _ -> Nothing

-- | The Responses API streaming caller.
responsesStream :: Text -> Text -> Text -> IO StreamCall
responsesStream baseUrl apiKey model = do
  let url = T.unpack (rootOf baseUrl) ++ "/v1/responses"
      headers = ("Content-Type", "application/json") : bearer apiKey
  pure $ \msgs specs onEvent -> do
    pending <- newIORef (Nothing :: Maybe (Text, Text))
    result <- LStream.streamPostSse url headers (responsesRequestBody model msgs specs True) $ \v -> do
      case responsesDelta v of
        Just txt | not (T.null txt) -> onEvent (ChunkDelta txt)
        _                           -> pure ()
      done <- responsesToolStep pending v
      mapM_ (\(nm, args) -> onEvent (ChunkToolCall nm args)) done
    case result of
      Left e   -> do onEvent (ChunkError e); pure (ChatTurn "" [] Nothing (Just e) Nothing)
      Right () -> pure (ChatTurn "" [] Nothing Nothing Nothing)

-- | @response.output_text.delta.delta@ from a streaming frame.
responsesDelta :: Value -> Maybe Text
responsesDelta v = case v of
  Object o -> case field "type" o of
    Just (String "response.output_text.delta") -> case field "delta" o of
      Just (String t) -> Just t
      _               -> Nothing
    _ -> Nothing
  _ -> Nothing

-- | @content_block_start@ opens a @tool_use@ block, @input_json_delta@ feeds
-- it, @content_block_stop@ closes it and yields the finished call.
anthropicToolStep :: IORef (Maybe (Text, Text)) -> Value -> IO (Maybe (Text, Text))
anthropicToolStep ref v = case v of
  Object o -> case field "type" o of
    Just (String "content_block_start") -> do
      case field "content_block" o of
        Just (Object b) | field "type" b == Just (String "tool_use") -> do
          writeIORef ref (Just (asText (field "name" b), ""))
          pure Nothing
        _ -> pure Nothing
    Just (String "content_block_delta") -> do
      m <- readIORef ref
      case (m, field "delta" o) of
        (Just (nm, acc), Just (Object d)) -> do
          writeIORef ref (Just (nm, acc <> asText (field "partial_json" d)))
          pure Nothing
        _ -> pure Nothing
    Just (String "content_block_stop") -> do
      m <- readIORef ref
      writeIORef ref Nothing
      pure m
    _ -> pure Nothing
  _ -> pure Nothing

-- | @response.output_item.added@ names a @function_call@, its arguments arrive
-- as @response.function_call_arguments.delta@, and @…done@ closes it.
responsesToolStep :: IORef (Maybe (Text, Text)) -> Value -> IO (Maybe (Text, Text))
responsesToolStep ref v = case v of
  Object o -> case field "type" o of
    Just (String "response.output_item.added") -> do
      case field "item" o of
        Just (Object it) | field "type" it == Just (String "function_call") -> do
          writeIORef ref (Just (asText (field "name" it), ""))
          pure Nothing
        _ -> pure Nothing
    Just (String "response.function_call_arguments.delta") -> do
      m <- readIORef ref
      case m of
        Just (nm, acc) -> do
          writeIORef ref (Just (nm, acc <> asText (field "delta" o)))
          pure Nothing
        Nothing -> pure Nothing
    Just (String "response.function_call_arguments.done") -> do
      m <- readIORef ref
      writeIORef ref Nothing
      pure m
    _ -> pure Nothing
  _ -> pure Nothing

-- | A JSON string field as plain text ('' when absent or not a string).
asText :: Maybe Value -> Text
asText (Just (String s)) = s
asText _                 = ""

-- | A JSON integer field.
jsonInt :: Text -> Object -> Maybe Int
jsonInt k o = case field k o of
  Just (Number n) -> Just (round n)
  _               -> Nothing

--------------------------------------------------------------------------------
-- OpenAI-compatible wire
--------------------------------------------------------------------------------

openAICompatAdapter :: Text -> Text -> Text -> IO LLMAdapter
openAICompatAdapter baseUrl apiKey model = do
  manager <- newManager tlsManagerSettings
  let url = T.unpack (T.dropWhileEnd (== '/') (T.strip baseUrl)) ++ "/chat/completions"
      headers = ("Content-Type", "application/json") : bearer apiKey
      call msgs specs = postJson manager url headers (buildDeepSeekChatRequest model msgs specs Nothing)
  stream <- openAICompatStream baseUrl apiKey model
  pure LLMAdapter
    { llmChat = \msgs -> do
        (code, body, ok) <- call (map toChat msgs) []
        if not ok
          then pure [ChunkError ("HTTP " <> T.pack (show code))]
          else case decode body of
                 Nothing -> pure [ChunkError "failed to parse the endpoint's response"]
                 Just v  -> case parseDeepSeekChatTurn v of
                   Left e  -> pure [ChunkError e]
                   Right t -> pure [ ChunkDelta (ctContent t)
                                   , ChunkDone (maybe (mkUsage 0 0 0) id (ctUsage t)) ]
    , llmChatTools = \msgs specs _gp -> do
        (code, body, ok) <- call msgs specs
        if not ok
          then pure (ChatTurn "" [] Nothing (Just
                 ("HTTP " <> T.pack (show code) <> ": "
                   <> T.take 500 (TE.decodeUtf8 (BL.toStrict body)))) Nothing)
          else case decode body of
                 Nothing -> pure (ChatTurn "" [] Nothing (Just "failed to parse the endpoint's response") Nothing)
                 Just v  -> pure (either (\e -> ChatTurn "" [] Nothing (Just e) Nothing) id (parseDeepSeekChatTurn v))
    , llmEmbed = \_ -> pure []
    , llmModels = pure [ModelInfo model "endpoint model" 32768]
    , llmChatToolsStream = stream
    }
  where
    toChat m = case messageRole m of
      System    -> ChatSystem (messageContent m)
      User      -> ChatUser (messageContent m)
      Assistant -> ChatAssistant (messageContent m) []

--------------------------------------------------------------------------------
-- Anthropic Messages wire
--------------------------------------------------------------------------------

-- | Anthropic's Messages API: @x-api-key@ (not Bearer) plus a version header,
-- a required @max_tokens@, a top-level @system@, and tool calls as
-- @tool_use@ / @tool_result@ content blocks.
anthropicAdapter :: Text -> Text -> Text -> IO LLMAdapter
anthropicAdapter baseUrl apiKey model = do
  manager <- newManager tlsManagerSettings
  let url = T.unpack (rootOf baseUrl) ++ "/v1/messages"
      headers = [ ("Content-Type", "application/json")
                , ("anthropic-version", "2023-06-01") ]
                ++ (if T.null (T.strip apiKey) then [] else [("x-api-key", TE.encodeUtf8 apiKey)])
      call msgs specs = postJson manager url headers (anthropicRequestBody model msgs specs)
  stream <- anthropicStream baseUrl apiKey model
  pure LLMAdapter
    { llmChat = \msgs -> do
        (code, body, ok) <- call (map toChat msgs) []
        if not ok
          then pure [ChunkError ("HTTP " <> T.pack (show code))]
          else case decode body of
                 Nothing -> pure [ChunkError "failed to parse the endpoint's response"]
                 Just v  -> case parseAnthropicTurn v of
                   Left e  -> pure [ChunkError e]
                   Right t -> pure [ ChunkDelta (ctContent t)
                                   , ChunkDone (maybe (mkUsage 0 0 0) id (ctUsage t)) ]
    , llmChatTools = \msgs specs _gp -> do
        (code, body, ok) <- call msgs specs
        if not ok
          then pure (ChatTurn "" [] Nothing (Just ("HTTP " <> T.pack (show code))) Nothing)
          else case decode body of
                 Nothing -> pure (ChatTurn "" [] Nothing (Just "failed to parse the endpoint's response") Nothing)
                 Just v  -> pure (either (\e -> ChatTurn "" [] Nothing (Just e) Nothing) id (parseAnthropicTurn v))
    , llmEmbed = \_ -> pure []
    , llmModels = pure [ModelInfo model "endpoint model" 32768]
    , llmChatToolsStream = stream
    }
  where
    toChat m = case messageRole m of
      System    -> ChatSystem (messageContent m)
      User      -> ChatUser (messageContent m)
      Assistant -> ChatAssistant (messageContent m) []

-- | Anthropic keeps the system prompt out of the message list, so it is
-- collected separately; tool results ride in a user turn as @tool_result@.
toAnthropicMessages :: [ChatMessage] -> (Text, [Value])
toAnthropicMessages msgs = (T.intercalate "\n\n" systems, go msgs)
  where
    systems = [ t | ChatSystem t <- msgs, not (T.null (T.strip t)) ]
    go [] = []
    go (m : rest) = case m of
      ChatSystem _ -> go rest
      ChatUser t   -> object [ "role" .= ("user" :: Text), "content" .= t ] : go rest
      ChatAssistant t calls ->
        object [ "role" .= ("assistant" :: Text), "content" .= assistantBlocks t calls ] : go rest
      ChatTool callId out ->
        let content = if T.null (T.strip out) then "(no output)" else out
        in object
             [ "role" .= ("user" :: Text)
             , "content" .= [ object
                 [ "type" .= ("tool_result" :: Text)
                 , "tool_use_id" .= callId
                 , "content" .= content
                 ] ]
             ] : go rest
    assistantBlocks t calls =
      [ object [ "type" .= ("text" :: Text), "text" .= t ] | not (T.null (T.strip t)) ]
      ++ [ object
             [ "type" .= ("tool_use" :: Text)
             , "id"   .= tcId c
             , "name" .= tcName c
             , "input" .= decodeInput (tcArguments c)
             ]
         | c <- calls ]

-- | A tool as Anthropic declares it.
anthropicTool :: ToolSpec -> Value
anthropicTool s = object
  [ "name"         .= tsName s
  , "description"  .= tsDescription s
  , "input_schema" .= tsParameters s
  ]

-- | A tool as the Responses API declares it.
responsesTool :: ToolSpec -> Value
responsesTool s = object
  [ "type"        .= ("function" :: Text)
  , "name"        .= tsName s
  , "description" .= tsDescription s
  , "parameters"  .= tsParameters s
  ]

-- | @{"content":[{"type":"text","text":…}|{"type":"tool_use",…}],"usage":{…}}@
parseAnthropicTurn :: Value -> Either Text ChatTurn
parseAnthropicTurn v = case v of
  Object o -> do
    let blocks = case field "content" o of
          Just (Array a) -> V.toList a
          _              -> []
        texts = [ t | Object b <- blocks
                    , Just (String ty) <- [field "type" b], ty == "text"
                    , Just (String t) <- [field "text" b] ]
        calls = [ ToolCall (str "id" b) (str "name" b) (jsonText (fromMaybe Null (field "input" b)))
                | Object b <- blocks
                , Just (String ty) <- [field "type" b], ty == "tool_use" ]
        (mi, mo) = case field "usage" o of
          Just (Object u) -> (int "input_tokens" u, int "output_tokens" u)
          _               -> (Nothing, Nothing)
        stop = case field "stop_reason" o of
          Just (String s) -> Just s
          _               -> Nothing
    Right (ChatTurn (T.concat texts) calls (Just (usageOf mi mo)) stop Nothing)
  _ -> Left "malformed Anthropic response"
  where
    str k o = case field k o of
      Just (String s) -> s
      _               -> ""
    int k o = case field k o of
      Just (Number n) -> Just (round n)
      _               -> Nothing

--------------------------------------------------------------------------------
-- OpenAI Responses wire
--------------------------------------------------------------------------------

-- | The Responses API: @input@ items rather than chat messages, tool calls as
-- @function_call@ / @function_call_output@ items, and the system prompt in
-- @instructions@.
responsesAdapter :: Text -> Text -> Text -> IO LLMAdapter
responsesAdapter baseUrl apiKey model = do
  manager <- newManager tlsManagerSettings
  let url = T.unpack (rootOf baseUrl) ++ "/v1/responses"
      headers = ("Content-Type", "application/json") : bearer apiKey
      call msgs specs = postJson manager url headers (responsesRequestBody model msgs specs False)
  stream <- responsesStream baseUrl apiKey model
  pure LLMAdapter
    { llmChat = \msgs -> do
        (code, body, ok) <- call (map toChat msgs) []
        if not ok
          then pure [ChunkError ("HTTP " <> T.pack (show code))]
          else case decode body of
                 Nothing -> pure [ChunkError "failed to parse the endpoint's response"]
                 Just v  -> case parseResponsesTurn v of
                   Left e  -> pure [ChunkError e]
                   Right t -> pure [ ChunkDelta (ctContent t)
                                   , ChunkDone (maybe (mkUsage 0 0 0) id (ctUsage t)) ]
    , llmChatTools = \msgs specs _gp -> do
        (code, body, ok) <- call msgs specs
        if not ok
          then pure (ChatTurn "" [] Nothing (Just ("HTTP " <> T.pack (show code))) Nothing)
          else case decode body of
                 Nothing -> pure (ChatTurn "" [] Nothing (Just "failed to parse the endpoint's response") Nothing)
                 Just v  -> pure (either (\e -> ChatTurn "" [] Nothing (Just e) Nothing) id (parseResponsesTurn v))
    , llmEmbed = \_ -> pure []
    , llmModels = pure [ModelInfo model "endpoint model" 32768]
    , llmChatToolsStream = stream
    }
  where
    toChat m = case messageRole m of
      System    -> ChatSystem (messageContent m)
      User      -> ChatUser (messageContent m)
      Assistant -> ChatAssistant (messageContent m) []

toResponsesInput :: [ChatMessage] -> (Text, [Value])
toResponsesInput msgs = (T.intercalate "\n\n" systems, concatMap one msgs)
  where
    systems = [ t | ChatSystem t <- msgs, not (T.null (T.strip t)) ]
    one m = case m of
      ChatSystem _ -> []
      ChatUser t   -> [ object [ "role" .= ("user" :: Text), "content" .= t ] ]
      ChatAssistant t calls ->
        [ object [ "role" .= ("assistant" :: Text), "content" .= t ]
          | not (T.null (T.strip t)) ]
        ++ [ object
               [ "type"      .= ("function_call" :: Text)
               , "call_id"   .= tcId c
               , "name"      .= tcName c
               , "arguments" .= tcArguments c
               ]
           | c <- calls ]
      ChatTool callId out ->
        [ object
            [ "type"    .= ("function_call_output" :: Text)
            , "call_id" .= callId
            , "output"  .= (if T.null (T.strip out) then "(no output)" else out)
            ]
        ]

-- | @{"output":[{"type":"message","content":[{"type":"output_text","text":…}]}
-- |{"type":"function_call","call_id":…,"name":…,"arguments":…}],"usage":{…}}@
parseResponsesTurn :: Value -> Either Text ChatTurn
parseResponsesTurn v = case v of
  Object o -> do
    let items = case field "output" o of
          Just (Array a) -> V.toList a
          _              -> []
        texts = [ t
                | Object it <- items
                , Just (String ty) <- [field "type" it], ty == "message"
                , Just (Array cs) <- [field "content" it]
                , Object c <- V.toList cs
                , Just (String ct) <- [field "type" c], ct == "output_text"
                , Just (String t) <- [field "text" c] ]
        calls = [ ToolCall (str "call_id" it) (str "name" it) (str "arguments" it)
                | Object it <- items
                , Just (String ty) <- [field "type" it], ty == "function_call" ]
        (mi, mo) = case field "usage" o of
          Just (Object u) -> (int "input_tokens" u, int "output_tokens" u)
          _               -> (Nothing, Nothing)
    Right (ChatTurn (T.concat texts) calls (Just (usageOf mi mo)) Nothing Nothing)
  _ -> Left "malformed Responses response"
  where
    str k o = case field k o of
      Just (String s) -> s
      _               -> ""
    int k o = case field k o of
      Just (Number n) -> Just (round n)
      _               -> Nothing

-- | Tool arguments arrive as a JSON string; Anthropic wants them as an object.
decodeInput :: Text -> Value
decodeInput raw = case decode (BL.fromStrict (TE.encodeUtf8 raw)) of
  Just v  -> v
  Nothing -> Object KM.empty
