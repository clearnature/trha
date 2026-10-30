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
  , mergeExtraBody
  , withEffort
  , withResponseEffort
  , invalidateProviderCaches
  , providerCacheSize
  , providerCacheFingerprint
  , openAICompatAdapter
  , anthropicAdapter
  , responsesAdapter
  , providerStream
  , openAICompatStream
  , anthropicStream
  , responsesStream
  , anthropicRequestBody
  , StreamCall
  ) where

import Control.Concurrent.MVar (MVar, newMVar, modifyMVar, modifyMVar_, withMVar)
import Data.Aeson (Object, Value(..), decode, encode, object, toJSON, (.=))
import Data.Aeson.Key (fromText, toText)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe, isNothing)
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
import Data.CaseInsensitive (mk)
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (statusCode, statusIsSuccessful)
import System.IO.Unsafe (unsafePerformIO)

import Core.Provider.Types
import LLM.Adapter.Interface (LLMAdapter(..), StreamCall)
import qualified LLM.Stream as LStream
import LLM.Adapter.Types
import LLM.Providers.DeepSeek (buildDeepSeekChatRequest, parseDeepSeekChatTurn)
import System.Environment (lookupEnv)


-- | One adapter per provider name, rebuilt only when its fingerprint
-- (entry fields + key) changes.  The Responses wire keeps its continuation
-- state inside the adapter, so rebuilding per request would silently drop
-- @previous_response_id@.
{-# NOINLINE providerAdapterCache #-}
providerAdapterCache :: MVar (Map.Map Text (Text, LLMAdapter))
providerAdapterCache = unsafePerformIO (newMVar Map.empty)

{-# NOINLINE providerStreamCache #-}
providerStreamCache :: MVar (Map.Map Text (Text, StreamCall))
providerStreamCache = unsafePerformIO (newMVar Map.empty)

-- | Everything an adapter's behaviour depends on, plus the key.
fingerprint :: ProviderEntry -> Text -> Text
fingerprint entry key = T.intercalate "|"
  [ peName entry, peKind entry, peBaseUrl entry, peDefault entry
  , T.intercalate "," (peModels entry)
  , T.pack (show (peHeaders entry)), T.pack (show (peExtraBody entry))
  , peThinking entry, peResponsesMode entry, key ]

-- | Drop every cached adapter/stream (after a provider is saved/removed).
invalidateProviderCaches :: IO ()
invalidateProviderCaches = do
  modifyMVar_ providerAdapterCache (const (pure Map.empty))
  modifyMVar_ providerStreamCache (const (pure Map.empty))

providerCacheFingerprint :: Text -> IO (Maybe Text)
providerCacheFingerprint name =
  withMVar providerAdapterCache (pure . fmap fst . Map.lookup name)

providerCacheSize :: IO Int
providerCacheSize =
  (+) <$> withMVar providerAdapterCache (pure . Map.size)
      <*> withMVar providerStreamCache (pure . Map.size)

-- | Build an adapter for a saved provider entry, given its key.
--
-- @"cpu"@ is the in-kernel local inference backend: no key, no network — for
-- this kind @peBaseUrl@ carries the **model path**.
adapterFor :: ProviderEntry -> Text -> IO (Either Text LLMAdapter)
adapterFor entry key = do
  let fp = fingerprint entry key
  cached <- withMVar providerAdapterCache (pure . Map.lookup (peName entry))
  case cached of
    Just (fp', a) | fp' == fp -> pure (Right a)
    _ -> do
      built <- buildAdapter entry key
      case built of
        Right a -> do
          modifyMVar_ providerAdapterCache (pure . Map.insert (peName entry) (fp, a))
          pure (Right a)
        Left e -> pure (Left e)

buildAdapter :: ProviderEntry -> Text -> IO (Either Text LLMAdapter)
buildAdapter entry key = case peKind entry of
  "openai"    -> Right <$> openAICompatAdapter (peBaseUrl entry) key (peDefault entry)
                       (extraHeaders (peHeaders entry)) (peExtraBody entry)
                       (effortOf entry)
  "anthropic" -> Right <$> anthropicAdapter (peBaseUrl entry) key (peDefault entry)
                       (extraHeaders (peHeaders entry)) (thinkingField (peThinking entry))
  "responses" -> Right <$> responsesAdapter (peBaseUrl entry) key (peDefault entry)
                       (extraHeaders (peHeaders entry)) (peExtraBody entry)
                       (peResponsesMode entry)
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

-- | A provider's default effort, unless it is blank or "auto".
effortOf :: ProviderEntry -> Maybe Text
effortOf entry =
  let e = T.strip (peEffort entry)
  in if T.null e || T.toLower e == "auto" then Nothing else Just e

-- | Extra HTTP headers declared by a gateway/relay (a JSON object of values).
extraHeaders :: Maybe Value -> [Header]
extraHeaders Nothing = []
extraHeaders (Just (Object o)) =
  [ (mk (TE.encodeUtf8 (toText k)), TE.encodeUtf8 (headerText v))
  | (k, v) <- KM.toList o ]
  where
    headerText (String v) = v
    headerText v          = jsonText v
extraHeaders _ = []

-- | Relay-declared extra top-level body fields; they win at leaves, while
-- nested objects merge recursively (a relay adding reasoning.effort must not
-- drop the generated reasoning.summary).
mergeExtraBody :: Maybe Value -> Value -> Value
mergeExtraBody Nothing base = base
mergeExtraBody (Just extra) base = deepMerge extra base

deepMerge :: Value -> Value -> Value
deepMerge (Object a) (Object b) =
  Object (KM.unionWith (\x y -> deepMerge x y) a b)
deepMerge a _ = a

-- | Insert a provider/request effort into an OpenAI-compatible body.
withEffort :: Maybe Text -> Value -> Value
withEffort Nothing v = v
withEffort (Just e) v
  | T.null (T.strip e) || T.toLower (T.strip e) == "auto" = v
  | otherwise = case v of
      Object o | KM.member "reasoning_effort" o -> v
      Object o -> Object (KM.insert "reasoning_effort" (String (T.strip e)) o)
      _ -> v

-- | The Responses wire spells effort as reasoning.effort (nested).
withResponseEffort :: Maybe Text -> Value -> Value
withResponseEffort Nothing v = v
withResponseEffort (Just e) v
  | T.null (T.strip e) || T.toLower (T.strip e) == "auto" = v
  | otherwise = mergeExtraBody
      (Just (object [ "reasoning" .= object [ "effort" .= T.strip e ] ])) v

-- | Anthropic extended-thinking mode (\@"adaptive"@ etc.); empty/disabled = off.
thinkingField :: Text -> Maybe Text
thinkingField t
  | T.null (T.strip t) = Nothing
  | T.toLower (T.strip t) == "disabled" = Nothing
  | otherwise = Just (T.strip t)

usageOf :: Maybe Int -> Maybe Int -> Usage
usageOf mi mo = mkUsage (fromMaybe 0 mi) (fromMaybe 0 mo) (fromMaybe 0 mi + fromMaybe 0 mo)

--------------------------------------------------------------------------------
-- Streaming (A2): the wire decides, not the adapter
--------------------------------------------------------------------------------

-- | A streaming caller for a saved provider.  A wire without a streaming path
-- falls back to the blocking adapter and emits its answer as one delta, so
-- callers always receive events.
providerStream :: ProviderEntry -> Text -> IO StreamCall
providerStream entry key = do
  let fp = fingerprint entry key
  cached <- withMVar providerStreamCache (pure . Map.lookup (peName entry))
  case cached of
    Just (fp', s0) | fp' == fp -> pure s0
    _ -> do
      s0 <- buildStream entry key
      modifyMVar_ providerStreamCache (pure . Map.insert (peName entry) (fp, s0))
      pure s0

buildStream :: ProviderEntry -> Text -> IO StreamCall
buildStream entry key = case peKind entry of
  "openai"    -> openAICompatStream (peBaseUrl entry) key (peDefault entry)
                       (extraHeaders (peHeaders entry)) (peExtraBody entry)
                       (effortOf entry)
  "anthropic" -> anthropicStream (peBaseUrl entry) key (peDefault entry)
                       (extraHeaders (peHeaders entry)) (thinkingField (peThinking entry))
  "responses" -> do
    ridRef <- newIORef (Map.empty :: Map.Map Text Text)
    responsesStream (peBaseUrl entry) key (peDefault entry)
      (extraHeaders (peHeaders entry)) (peExtraBody entry)
      (effortOf entry) (peResponsesMode entry) ridRef
  _        -> do
    built <- adapterFor entry key
    pure $ case built of
      Right a   -> blockingStream a
      Left why  -> \_ _ _ onEvent -> do
        onEvent (ChunkError why)
        pure (ChatTurn "" [] Nothing (Just why) Nothing Nothing)
  where
    -- The blocking call, announced as one delta: a wire with no streaming
    -- path still gives the caller events it can forward.
    blockingStream a msgs specs gp onEvent = do
      turn <- llmChatTools a msgs specs gp
      onEvent (ChunkDelta (ctContent turn))
      onEvent (ChunkDone (maybe (mkUsage 0 0 0) id (ctUsage turn)))
      pure turn

-- | An OpenAI-compatible streaming caller.  The SSE transport and the
-- tool-call aggregation live in LLM.Stream, so every OpenAI-compatible wire —
-- saved providers and the DeepSeek/OpenAI adapters alike — shares one engine.
openAICompatStream :: Text -> Text -> Text -> [Header] -> Maybe Value -> Maybe Text -> IO StreamCall
openAICompatStream baseUrl apiKey model extraHs extraBody meffort =
  pure $ \msgs specs gp onEvent -> do
    let eff = case gpEffort gp of
                Just e | T.toLower (T.strip e) /= "auto" -> Just e
                _ -> meffort
        base = mergeExtraBody extraBody (buildDeepSeekChatRequest model msgs specs Nothing)
        base' = withEffort eff base
        body = case base' of
          Object o -> Object (KM.insert "stream" (Bool True) o)
          other    -> other
        headers = ("Content-Type", "application/json") : (bearer apiKey ++ extraHs)
    LStream.openAICompatStreamCall
      (T.unpack (T.dropWhileEnd (== '/') (T.strip baseUrl)) ++ "/chat/completions")
      headers body onEvent

-- | The Messages API body, shared by the blocking and the streaming caller.
-- Without @stream: true@ the endpoint answers with one JSON body, so the SSE
-- parser sees no frames and the reply silently disappears.
anthropicRequestBody :: Text -> [ChatMessage] -> [ToolSpec] -> Bool -> Maybe Text -> Value
anthropicRequestBody model msgs specs streaming mthinking =
  let (systemText, turns) = toAnthropicMessages msgs
  in object $
       [ "model"      .= model
       , "max_tokens" .= (4096 :: Int)
       , "messages"   .= turns
       , "stream"     .= streaming
       ] ++ [ "system" .= systemText | not (T.null systemText) ]
         -- Thinking is the provider default.  It is disabled only when a
         -- tool-bearing assistant turn has no signature to replay (legacy
         -- transcripts): DeepSeek rejects a tool round without its thinking
         -- block, and an empty block cannot be fabricated.
         ++ [ "thinking" .= object [ "type" .= t ] | Just t <- [mthinking] ]
         ++ [ "thinking" .= object [ "type" .= ("disabled" :: Text) ]
            | needsThinkingDisabled, isNothing mthinking ]
         ++ [ "tools"  .= anthropicTools specs | not (null specs) ]
  where
    needsThinkingDisabled = any legacyToolTurn msgs
    legacyToolTurn m = case m of
      ChatAssistant _ calls            -> not (null calls)
      ChatAssistantThought _ calls _ s -> not (null calls) && isNothing s
      _                                -> False

-- | The Responses API body, shared by the blocking and the streaming caller.
responsesRequestBody :: Text -> [ChatMessage] -> [ToolSpec] -> Bool -> Maybe Text -> Value
responsesRequestBody model msgs specs streaming mprev =
  let (instructions, items) = toResponsesInput msgs
  in object $
       [ "model" .= model, "input" .= items, "stream" .= streaming ]
       ++ [ "previous_response_id" .= rid | Just rid <- [mprev] ]
       ++ [ "instructions" .= instructions | not (T.null instructions) ]
       ++ [ "tools" .= map responsesTool specs | not (null specs) ]

-- | Anthropic's streaming caller: SSE with named events.
anthropicStream :: Text -> Text -> Text -> [Header] -> Maybe Text -> IO StreamCall
anthropicStream baseUrl apiKey model extraHs mthinking = do
  let url = T.unpack (rootOf baseUrl) ++ "/v1/messages"
      headers = ([ ("Content-Type", "application/json")
                 , ("anthropic-version", "2023-06-01") ]
                ++ [("x-api-key", TE.encodeUtf8 apiKey) | not (T.null (T.strip apiKey))])
                ++ extraHs
  pure $ \msgs specs _gp onEvent -> do
    pending <- newIORef (Nothing :: Maybe (Int, Text, Text, Text))
    thinkingRef <- newIORef T.empty
    sigRef <- newIORef (Nothing :: Maybe Text)
    result <- LStream.streamPostSse url headers (anthropicRequestBody model msgs specs True mthinking) $ \v -> do
      case anthropicEvent v of
        Just (Left txt) -> onEvent (ChunkDelta txt)
        Just (Right u)  -> onEvent (ChunkDone u)
        Nothing         -> pure ()
      case anthropicThinking v of
        Just (Left txt) -> do
          modifyIORef' thinkingRef (<> txt)
          onEvent (ChunkReasoning txt)
        Just (Right sig) -> do
          writeIORef sigRef (Just sig)
          onEvent (ChunkReasoningSignature sig)
        Nothing -> pure ()
      done <- anthropicToolStep pending v
      mapM_ (\(idx, tid, nm, args) -> onEvent (ChunkToolCallAt idx tid nm args)) done
    reasoning <- readIORef thinkingRef
    sig <- readIORef sigRef
    let mreasoning = if T.null reasoning then Nothing else Just reasoning
    case result of
      Left e   -> do onEvent (ChunkError e)
                     pure (ChatTurn "" [] Nothing (Just e) mreasoning sig)
      Right () -> pure (ChatTurn "" [] Nothing Nothing mreasoning sig)

-- | Thinking blocks on the Anthropic wire: @thinking_delta.delta.thinking@
-- is the chain text, @signature_delta.delta.signature@ is the block's
-- signature (must be replayed with the block on the next tool round).
anthropicThinking :: Value -> Maybe (Either Text Text)
anthropicThinking v = case v of
  Object o -> case field "type" o of
    Just (String "content_block_delta") -> case field "delta" o of
      Just (Object d) -> case field "type" d of
        Just (String "thinking_delta")  -> Left  <$> asTextOpt (field "thinking" d)
        Just (String "signature_delta") -> Right <$> asTextOpt (field "signature" d)
        _                               -> Nothing
      _ -> Nothing
    _ -> Nothing
  _ -> Nothing
  where
    asTextOpt (Just (String t)) = Just t
    asTextOpt _                 = Nothing

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
responsesStream :: Text -> Text -> Text -> [Header] -> Maybe Value -> Maybe Text -> Text -> IORef (Map.Map Text Text) -> IO StreamCall
responsesStream baseUrl apiKey model extraHs extraBody meffort mode ridRef = do
  let url = T.unpack (rootOf baseUrl) ++ "/v1/responses"
      headers = ("Content-Type", "application/json") : (bearer apiKey ++ extraHs)
  pure $ \msgs specs gp onEvent -> do
    pending <- newIORef (Nothing :: Maybe (Int, Text, Text, Text))
    let skey = fromMaybe "" (gpSessionId gp)
        eff = case gpEffort gp of
                Just e | T.toLower (T.strip e) /= "auto" -> Just e
                _ -> meffort
    prev <- if mode == "stateful"
              then Map.lookup skey <$> readIORef ridRef
              else pure Nothing
    let onFrame v = do
          -- response.completed carries the id the next turn continues from.
          case v of
            Object o | field "type" o == Just (String "response.completed") ->
              case field "response" o >>= responsesResponseId of
                Just rid -> modifyIORef' ridRef (Map.insert skey rid)
                Nothing  -> pure ()
            _ -> pure ()
          case responsesDelta v of
            Just txt | not (T.null txt) -> onEvent (ChunkDelta txt)
            _                           -> pure ()
          done <- responsesToolStep pending v
          mapM_ (\(idx, cid, nm, args) -> onEvent (ChunkToolCallAt idx cid nm args)) done
        attempt p = do
          writeIORef pending Nothing
          LStream.streamPostSse url headers
            (withResponseEffort eff (mergeExtraBody extraBody (responsesRequestBody model msgs specs True p))) onFrame
    first <- attempt prev
    -- A rejected continuation (typically HTTP 400) is recoverable: retry with
    -- the full history and no previous_response_id, like the blocking path.
    result <- case (first, prev) of
      (Left _, Just _) -> attempt Nothing
      _                -> pure first
    case result of
      Left e   -> do onEvent (ChunkError e); pure (ChatTurn "" [] Nothing (Just e) Nothing Nothing)
      Right () -> pure (ChatTurn "" [] Nothing Nothing Nothing Nothing)

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
anthropicToolStep :: IORef (Maybe (Int, Text, Text, Text)) -> Value -> IO (Maybe (Int, Text, Text, Text))
anthropicToolStep ref v = case v of
  Object o -> case field "type" o of
    Just (String "content_block_start") -> do
      case field "content_block" o of
        Just (Object b) | field "type" b == Just (String "tool_use") -> do
          -- The provider's tool_use id is mandatory on the next request's
          -- tool_result; without it DeepSeek rejects the round with 400.
          writeIORef ref (Just (asInt (field "index" o), asText (field "id" b),
                                asText (field "name" b), ""))
          pure Nothing
        _ -> pure Nothing
    Just (String "content_block_delta") -> do
      m <- readIORef ref
      case (m, field "delta" o) of
        (Just (idx, tid, nm, acc), Just (Object d)) -> do
          writeIORef ref (Just (idx, tid, nm, acc <> asText (field "partial_json" d)))
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
responsesToolStep :: IORef (Maybe (Int, Text, Text, Text)) -> Value -> IO (Maybe (Int, Text, Text, Text))
responsesToolStep ref v = case v of
  Object o -> case field "type" o of
    Just (String "response.output_item.added") -> do
      case field "item" o of
        Just (Object it) | field "type" it == Just (String "function_call") -> do
          -- call_id pairs the function_call_output on the next request; an
          -- empty one is rejected (input[n].call_id must be non-empty).
          let cid = case asText (field "call_id" it) of
                      "" -> asText (field "id" it)
                      c  -> c
          writeIORef ref (Just (asInt (field "output_index" o), cid,
                                asText (field "name" it), ""))
          pure Nothing
        _ -> pure Nothing
    Just (String "response.function_call_arguments.delta") -> do
      m <- readIORef ref
      case m of
        Just (idx, cid, nm, acc) -> do
          writeIORef ref (Just (idx, cid, nm, acc <> asText (field "delta" o)))
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

-- | A JSON number as Int (0 when absent).
asInt :: Maybe Value -> Int
asInt (Just (Number n)) = round n
asInt _                 = 0

-- | A JSON integer field.
jsonInt :: Text -> Object -> Maybe Int
jsonInt k o = case field k o of
  Just (Number n) -> Just (round n)
  _               -> Nothing

--------------------------------------------------------------------------------
-- OpenAI-compatible wire
--------------------------------------------------------------------------------

openAICompatAdapter :: Text -> Text -> Text -> [Header] -> Maybe Value -> Maybe Text -> IO LLMAdapter
openAICompatAdapter baseUrl apiKey model extraHs extraBody meffort = do
  manager <- newManager tlsManagerSettings
  let url = T.unpack (T.dropWhileEnd (== '/') (T.strip baseUrl)) ++ "/chat/completions"
      headers = ("Content-Type", "application/json") : (bearer apiKey ++ extraHs)
      call msgs specs = postJson manager url headers
        (withEffort meffort (mergeExtraBody extraBody (buildDeepSeekChatRequest model msgs specs Nothing)))
  stream <- openAICompatStream baseUrl apiKey model extraHs extraBody meffort
  pure LLMAdapter
    { llmChat = \msgs -> do
        (code, body, ok) <- call (map toChat msgs) []
        if not ok
          then pure [ChunkError ("HTTP " <> T.pack (show code) <> ": "
                             <> T.take 500 (TE.decodeUtf8 (BL.toStrict body)))]
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
                   <> T.take 500 (TE.decodeUtf8 (BL.toStrict body)))) Nothing Nothing)
          else case decode body of
                 Nothing -> pure (ChatTurn "" [] Nothing (Just "failed to parse the endpoint's response") Nothing Nothing)
                 Just v  -> pure (either (\e -> ChatTurn "" [] Nothing (Just e) Nothing Nothing) id (parseDeepSeekChatTurn v))
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
anthropicAdapter :: Text -> Text -> Text -> [Header] -> Maybe Text -> IO LLMAdapter
anthropicAdapter baseUrl apiKey model extraHs mthinking = do
  manager <- newManager tlsManagerSettings
  let url = T.unpack (rootOf baseUrl) ++ "/v1/messages"
      headers = ([ ("Content-Type", "application/json")
                 , ("anthropic-version", "2023-06-01") ]
                ++ (if T.null (T.strip apiKey) then [] else [("x-api-key", TE.encodeUtf8 apiKey)]))
                ++ extraHs
      call msgs specs = postJson manager url headers
        (anthropicRequestBody model msgs specs False mthinking)
  stream <- anthropicStream baseUrl apiKey model extraHs mthinking
  pure LLMAdapter
    { llmChat = \msgs -> do
        (code, body, ok) <- call (map toChat msgs) []
        if not ok
          then pure [ChunkError ("HTTP " <> T.pack (show code) <> ": "
                             <> T.take 500 (TE.decodeUtf8 (BL.toStrict body)))]
          else case decode body of
                 Nothing -> pure [ChunkError "failed to parse the endpoint's response"]
                 Just v  -> case parseAnthropicTurn v of
                   Left e  -> pure [ChunkError e]
                   Right t -> pure [ ChunkDelta (ctContent t)
                                   , ChunkDone (maybe (mkUsage 0 0 0) id (ctUsage t)) ]
    , llmChatTools = \msgs specs _gp -> do
        (code, body, ok) <- call msgs specs
        if not ok
          then pure (ChatTurn "" [] Nothing (Just ("HTTP " <> T.pack (show code) <> ": "
                   <> T.take 500 (TE.decodeUtf8 (BL.toStrict body)))) Nothing Nothing)
          else case decode body of
                 Nothing -> pure (ChatTurn "" [] Nothing (Just "failed to parse the endpoint's response") Nothing Nothing)
                 Just v  -> pure (either (\e -> ChatTurn "" [] Nothing (Just e) Nothing Nothing) id (parseAnthropicTurn v))
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
        object [ "role" .= ("assistant" :: Text), "content" .= assistantBlocks t calls Nothing ] : go rest
      ChatAssistantThought t calls reasoning sig ->
        object [ "role" .= ("assistant" :: Text)
               , "content" .= assistantBlocks t calls (Just (reasoning, sig)) ] : go rest
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
    assistantBlocks :: Text -> [ToolCall] -> Maybe (Text, Maybe Text) -> [Value]
    assistantBlocks t calls thinking =
      thinkingBlock thinking
      ++ [ object [ "type" .= ("text" :: Text), "text" .= t ] | not (T.null (T.strip t)) ]
      ++ [ object
             [ "type" .= ("tool_use" :: Text)
             , "id"   .= tcId c
             , "name" .= tcName c
             , "input" .= decodeInput (tcArguments c)
             ]
         | c <- calls ]

    -- A signed thinking block must come back verbatim on a tool round.
    thinkingBlock (Just (txt, Just sig)) =
      [ object [ "type" .= ("thinking" :: Text), "thinking" .= txt, "signature" .= sig ] ]
    thinkingBlock _ = []

-- | A tool as Anthropic declares it.
-- | Anthropic's tools array, with the provider's own constraint applied.
--
-- DeepSeek's anthropic-compatible endpoint rejects a request where *every* tool
-- carries @defer_loading: true@:
--
-- > tools: at least one tool must have defer_loading=false.
-- > All tools cannot be deferred.
--
-- When that happens we undefer the first tool instead of sending a request we
-- already know is invalid; the loss is one eager declaration, not a failed turn.
anthropicTools :: [ToolSpec] -> [Value]
anthropicTools [] = []
anthropicTools specs@(first : rest)
  | all tsDeferLoading specs =
      anthropicTool first { tsDeferLoading = False } : map anthropicTool rest
  | otherwise = map anthropicTool specs

anthropicTool :: ToolSpec -> Value
anthropicTool s = object $
  [ "name"         .= tsName s
  , "description"  .= tsDescription s
  , "input_schema" .= tsParameters s
  ]
  -- Anthropic's own field name. Only sent when set, so every other provider
  -- and every unflagged tool keeps the exact previous body.
  ++ [ "defer_loading" .= True | tsDeferLoading s ]

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
        thinking = [ (str "thinking" b, str "signature" b)
                   | Object b <- blocks
                   , Just (String ty) <- [field "type" b], ty == "thinking" ]
        reasoning = T.concat [ t | (t, _) <- thinking ]
        signature = case [ sig | (_, sig) <- thinking, not (T.null sig) ] of
          (sig : _) -> Just sig
          []        -> Nothing
        (mi, mo) = case field "usage" o of
          Just (Object u) -> (int "input_tokens" u, int "output_tokens" u)
          _               -> (Nothing, Nothing)
        stop = case field "stop_reason" o of
          Just (String s) -> Just s
          _               -> Nothing
    Right (ChatTurn (T.concat texts) calls (Just (usageOf mi mo)) stop
                    (if T.null reasoning then Nothing else Just reasoning) signature)
  _ -> Left "malformed Anthropic response"
  where
    str k o = case field k o of
      Just (String s) -> s
      _               -> ""
    nonEmpty a b = if T.null a then b else a
    int k o = case field k o of
      Just (Number n) -> Just (round n)
      _               -> Nothing

--------------------------------------------------------------------------------
-- OpenAI Responses wire
--------------------------------------------------------------------------------

-- | The Responses API: @input@ items rather than chat messages, tool calls as
-- @function_call@ / @function_call_output@ items, and the system prompt in
-- @instructions@.
responsesAdapter :: Text -> Text -> Text -> [Header] -> Maybe Value -> Text -> IO LLMAdapter
responsesAdapter baseUrl apiKey model extraHs extraBody mode = do
  manager <- newManager tlsManagerSettings
  ridRef <- newIORef (Map.empty :: Map.Map Text Text)
  let url = T.unpack (rootOf baseUrl) ++ "/v1/responses"
      headers = ("Content-Type", "application/json") : (bearer apiKey ++ extraHs)
      call skey msgs specs = do
        prev <- if mode == "stateful"
                  then Map.lookup skey <$> readIORef ridRef
                  else pure Nothing
        (code, body, ok) <- postJson manager url headers
          (mergeExtraBody extraBody (responsesRequestBody model msgs specs False prev))
        case (ok, prev) of
          -- The endpoint refused the continuation: retry with full history,
          -- exactly Reasonix's ContinuationRecoveryError path.
          (False, Just _) | code == 400 -> do
            (code2, body2, ok2) <- postJson manager url headers
              (mergeExtraBody extraBody (responsesRequestBody model msgs specs False Nothing))
            case decode body2 of
              Just v | ok2, Just rid <- responsesResponseId v ->
                modifyIORef' ridRef (Map.insert skey rid) >> pure (code2, body2, ok2)
              _ -> pure (code2, body2, ok2)
          _ -> do
            case decode body of
              Just v | ok, Just rid <- responsesResponseId v ->
                modifyIORef' ridRef (Map.insert skey rid)
              _ -> pure ()
            pure (code, body, ok)
  stream <- responsesStream baseUrl apiKey model extraHs extraBody Nothing mode ridRef
  pure LLMAdapter
    { llmChat = \msgs -> do
        (code, body, ok) <- call "" (map toChat msgs) []
        if not ok
          then pure [ChunkError ("HTTP " <> T.pack (show code) <> ": "
                             <> T.take 500 (TE.decodeUtf8 (BL.toStrict body)))]
          else case decode body of
                 Nothing -> pure [ChunkError "failed to parse the endpoint's response"]
                 Just v  -> case parseResponsesTurn v of
                   Left e  -> pure [ChunkError e]
                   Right t -> pure [ ChunkDelta (ctContent t)
                                   , ChunkDone (maybe (mkUsage 0 0 0) id (ctUsage t)) ]
    , llmChatTools = \msgs specs gp -> do
        let skey = fromMaybe "" (gpSessionId gp)
        (code, body, ok) <- call skey msgs specs
        if not ok
          then pure (ChatTurn "" [] Nothing (Just ("HTTP " <> T.pack (show code) <> ": "
                   <> T.take 500 (TE.decodeUtf8 (BL.toStrict body)))) Nothing Nothing)
          else case decode body of
                 Nothing -> pure (ChatTurn "" [] Nothing (Just "failed to parse the endpoint's response") Nothing Nothing)
                 Just v  -> pure (either (\e -> ChatTurn "" [] Nothing (Just e) Nothing Nothing) id (parseResponsesTurn v))
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
      ChatAssistantThought t calls _ _ ->
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
        calls = [ ToolCall (nonEmpty (str "call_id" it) (str "id" it))
                            (str "name" it) (str "arguments" it)
                | Object it <- items
                , Just (String ty) <- [field "type" it], ty == "function_call" ]
        (mi, mo) = case field "usage" o of
          Just (Object u) -> (int "input_tokens" u, int "output_tokens" u)
          _               -> (Nothing, Nothing)
    Right (ChatTurn (T.concat texts) calls (Just (usageOf mi mo)) Nothing Nothing Nothing)
  _ -> Left "malformed Responses response"
  where
    str k o = case field k o of
      Just (String s) -> s
      _               -> ""
    nonEmpty a b = if T.null a then b else a
    int k o = case field k o of
      Just (Number n) -> Just (round n)
      _               -> Nothing

-- | The @id@ of a Responses answer, used as the next turn's
-- @previous_response_id@ (stateful continuation).
responsesResponseId :: Value -> Maybe Text
responsesResponseId v = case v of
  Object o -> case field "id" o of
    Just (String i) -> Just i
    _               -> Nothing
  _ -> Nothing

-- | Tool arguments arrive as a JSON string; Anthropic wants them as an object.
decodeInput :: Text -> Value
decodeInput raw = case decode (BL.fromStrict (TE.encodeUtf8 raw)) of
  Just v  -> v
  Nothing -> Object KM.empty
