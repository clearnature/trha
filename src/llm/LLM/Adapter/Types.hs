{-# LANGUAGE OverloadedStrings #-}

module LLM.Adapter.Types
  ( Message(..)
  , StreamChunk(..)
  , ModelInfo(..)
  , Usage(..)
  , mkUsage
  , usageCacheHitRatio
  , Role(..)
    -- * Function calling (Phase 3 K1)
  , ToolSpec(..)
  , ToolCall(..)
  , ChatMessage(..)
  , ChatTurn(..)
  , GenParams(..)
  , defaultGenParams
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Aeson
import Data.Aeson.Types (Parser, (.:), (.:?), (.!=), withObject)

-- | Message role
data Role = System | User | Assistant
  deriving (Show, Eq)

instance ToJSON Role where
  toJSON System    = String "system"
  toJSON User      = String "user"
  toJSON Assistant = String "assistant"

instance FromJSON Role where
  parseJSON (String "system")    = pure System
  parseJSON (String "user")      = pure User
  parseJSON (String "assistant") = pure Assistant
  parseJSON _                    = fail "Invalid role"

-- | A message in the conversation
data Message = Message
  { messageRole    :: Role
  , messageContent :: Text
  } deriving (Show, Eq)

instance ToJSON Message where
  toJSON m = object
    [ "role"    .= messageRole m
    , "content" .= messageContent m
    ]

instance FromJSON Message where
  parseJSON = withObject "Message" $ \v ->
    Message <$> v .: "role" <*> v .: "content"

-- | Stream chunks from the LLM
data StreamChunk
  = ChunkDelta Text           -- ^ Partial text content
  | ChunkReasoning Text       -- ^ Partial thinking-mode content
  | ChunkReasoningSignature Text
      -- ^ Thinking-block signature (Anthropic wire): must be replayed with
      -- the thinking block on the next tool round.
  | ChunkToolCall Text Text   -- ^ Tool call (name, arguments JSON)
  | ChunkToolCallAt Int Text Text Text
      -- ^ Tool call with its stream index and provider id. Parallel calls need
      -- both: without the index clients merge them into one.
  | ChunkDone Usage           -- ^ Stream complete with usage stats
  | ChunkError Text           -- ^ Error during streaming
  deriving (Show, Eq)

-- | Model information
data ModelInfo = ModelInfo
  { modelName        :: Text
  , modelDescription :: Text
  , modelContextSize :: Int
  } deriving (Show, Eq)

instance ToJSON ModelInfo where
  toJSON m = object
    [ "id"           .= modelName m
    , "object"       .= ("model" :: Text)
    , "created"      .= (0 :: Int)
    , "owned_by"     .= ("trha" :: Text)
    , "description"  .= modelDescription m
    , "context_size" .= modelContextSize m
    ]

-- | Usage statistics.
--
-- The two cache fields are what make prefix caching measurable: DeepSeek bills
-- cached prompt tokens at a fraction of the miss rate, so a hit ratio that is
-- not observable is a cost that is not controllable. Providers that do not
-- report them leave both at zero ('mkUsage').
data Usage = Usage
  { usagePromptTokens     :: Int
  , usageCompletionTokens :: Int
  , usageTotalTokens      :: Int
  , usageCacheHitTokens   :: Int   -- ^ prompt tokens served from the prefix cache
  , usageCacheMissTokens  :: Int   -- ^ prompt tokens that had to be processed
  } deriving (Show, Eq)

-- | Usage without cache accounting.
mkUsage :: Int -> Int -> Int -> Usage
mkUsage p c t = Usage p c t 0 0

-- | Share of prompt tokens served from cache (0 when nothing was reported).
usageCacheHitRatio :: Usage -> Double
usageCacheHitRatio u =
  let denom = usageCacheHitTokens u + usageCacheMissTokens u
  in if denom <= 0 then 0 else fromIntegral (usageCacheHitTokens u) / fromIntegral denom

instance FromJSON Usage where
  parseJSON = withObject "Usage" $ \o -> do
    p <- o .:? "prompt_tokens" .!= 0
    c <- o .:? "completion_tokens" .!= 0
    t <- o .:? "total_tokens" .!= (p + c)
    hit <- o .:? "prompt_cache_hit_tokens" .!= 0
    miss <- o .:? "prompt_cache_miss_tokens" .!= max 0 (p - hit)
    pure (Usage p c t hit miss)

instance ToJSON Usage where
  toJSON u = object
    [ "prompt_tokens"            .= usagePromptTokens u
    , "completion_tokens"        .= usageCompletionTokens u
    , "total_tokens"             .= usageTotalTokens u
    , "prompt_cache_hit_tokens"  .= usageCacheHitTokens u
    , "prompt_cache_miss_tokens" .= usageCacheMissTokens u
    ]

--------------------------------------------------------------------------------
-- Function calling (Phase 3 K1)
-- OpenAI-compatible tool schema/call types.  The legacy Message/Role/
-- StreamChunk types stay untouched for compatibility; the agent loop and
-- provider extension use these.
--------------------------------------------------------------------------------

-- | OpenAI tool definition (@tools[]@ request field).
data ToolSpec = ToolSpec
  { tsName        :: Text
  , tsDescription :: Text
  , tsParameters  :: Value -- ^ JSON schema object
  , tsDeferLoading :: Bool
    -- ^ Anthropic's @defer_loading@: let the provider pull this definition into
    -- context on demand instead of declaring it up front. Providers without the
    -- feature ignore it, so the flag is safe to set unconditionally.
  } deriving (Show, Eq)

-- | One assistant turn from a function-calling request.
data ChatTurn = ChatTurn
  { ctContent   :: Text
  , ctToolCalls :: [ToolCall]
  , ctUsage     :: Maybe Usage
  , ctError     :: Maybe Text
  , ctReasoning :: Maybe Text  -- ^ thinking-mode chain, echoed back on tool turns
  , ctReasoningSignature :: Maybe Text
      -- ^ provider signature of the thinking block (Anthropic wire)
  } deriving (Show, Eq)

-- | A tool invocation emitted by the model (assistant @tool_calls@).
data ToolCall = ToolCall
  { tcId        :: Text
  , tcName      :: Text
  , tcArguments :: Text -- ^ raw JSON arguments string
  } deriving (Show, Eq)

-- | Conversation messages with full function-calling support.
data ChatMessage
  = ChatSystem Text
  | ChatUser Text
  | ChatAssistant Text [ToolCall] -- ^ content may be empty when tools are called
  | ChatAssistantThought Text [ToolCall] Text (Maybe Text)
      -- ^ assistant turn that carries the provider's @reasoning_content@
      -- (and, on the Anthropic wire, the thinking block's signature)
  | ChatTool Text Text             -- ^ tool_call_id, result content
  deriving (Show, Eq)


-- | 模型生成参数（LLM 设置预设；Nothing = 用内核/provider 默认）。
data GenParams = GenParams
  { gpTemperature :: Maybe Double
  , gpTopP        :: Maybe Double
  , gpMaxTokens   :: Maybe Int
  , gpEffort      :: Maybe Text   -- ^ reasoning_effort (auto = unset)
  , gpSessionId   :: Maybe Text   -- ^ kernel session key (stateful continuation)
  } deriving (Show, Eq)

defaultGenParams :: GenParams
defaultGenParams = GenParams Nothing Nothing Nothing Nothing Nothing

instance ToJSON ToolSpec where
  toJSON ts = object $
    [ "type" .= ("function" :: Text)
    , "function" .= object
        [ "name" .= tsName ts
        , "description" .= tsDescription ts
        , "parameters" .= tsParameters ts
        ]
    ]
    ++ [ "deferLoading" .= True | tsDeferLoading ts ]

instance FromJSON ToolSpec where
  parseJSON = withObject "ToolSpec" $ \v -> do
    fn <- v .: "function"
    -- The flag rides at the top level (next to `function`), which is where the
    -- scheduler puts it; an absent field means "declare it normally".
    defer' <- v .:? "deferLoading" .!= False
    ToolSpec <$> fn .: "name" <*> fn .: "description" <*> fn .: "parameters"
             <*> pure defer'

instance ToJSON ToolCall where
  toJSON tc = object
    [ "id" .= tcId tc
    , "type" .= ("function" :: Text)
    , "function" .= object
        [ "name" .= tcName tc
        , "arguments" .= tcArguments tc
        ]
    ]

instance FromJSON ToolCall where
  parseJSON = withObject "ToolCall" $ \v -> do
    fn <- v .: "function"
    ToolCall <$> v .: "id" <*> fn .: "name" <*> fn .: "arguments"

instance ToJSON ChatMessage where
  toJSON (ChatSystem content) = object ["role" .= ("system" :: Text), "content" .= content]
  toJSON (ChatUser content)   = object ["role" .= ("user" :: Text), "content" .= content]
  toJSON (ChatAssistant content calls) = object $
    [ "role" .= ("assistant" :: Text), "content" .= content ]
      ++ [ "tool_calls" .= calls | not (null calls) ]
      -- Thinking mode requires the field back on an assistant turn that
      -- carries tool calls; omitting it is a 400. When the reasoning text was
      -- retained the thought variant is used instead; this branch only fires
      -- for turns whose reasoning was never captured.
      ++ [ "reasoning_content" .= ("" :: Text) | not (null calls) ]
  toJSON (ChatAssistantThought content calls reasoning sig) = object $
    [ "role" .= ("assistant" :: Text)
    , "content" .= content
    , "reasoning_content" .= reasoning
    ]
      ++ [ "tool_calls" .= calls | not (null calls) ]
      ++ [ "reasoning_signature" .= s | Just s <- [sig] ]
  toJSON (ChatTool callId content) = object
    [ "role" .= ("tool" :: Text)
    , "tool_call_id" .= callId
    , "content" .= content
    ]

instance FromJSON ChatMessage where
  parseJSON = withObject "ChatMessage" $ \v -> do
    role <- v .: "role" :: Parser Text
    case role of
      "system"    -> ChatSystem <$> v .: "content"
      "user"      -> ChatUser <$> v .: "content"
      "assistant" -> do
        content <- v .: "content"
        calls <- v .:? "tool_calls" .!= []
        reasoning <- v .:? "reasoning_content"
        sig <- v .:? "reasoning_signature"
        -- An empty string means "no chain was captured" (older callers, or a
        -- model without thinking): keep it as a plain assistant turn so a
        -- decode/encode round-trip does not change the constructor.  A
        -- signature alone is enough to require the thought variant.
        pure $ case (reasoning, sig) of
          (Just r, s) | not (T.null r) -> ChatAssistantThought content calls r s
          (_, Just s)                  -> ChatAssistantThought content calls "" (Just s)
          _                            -> ChatAssistant content calls
      "tool"      -> ChatTool <$> v .: "tool_call_id" <*> v .: "content"
      _           -> fail "Invalid chat role"
