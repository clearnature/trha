{-# LANGUAGE OverloadedStrings #-}

module LLM.Adapter.Types
  ( Message(..)
  , StreamChunk(..)
  , ModelInfo(..)
  , Usage(..)
  , Role(..)
    -- * Function calling (Phase 3 K1)
  , ToolSpec(..)
  , ToolCall(..)
  , ChatMessage(..)
  , ChatTurn(..)
  ) where

import Data.Text (Text)
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
  | ChunkToolCall Text Text   -- ^ Tool call (name, arguments JSON)
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

-- | Usage statistics
data Usage = Usage
  { usagePromptTokens     :: Int
  , usageCompletionTokens :: Int
  , usageTotalTokens      :: Int
  } deriving (Show, Eq)

instance ToJSON Usage where
  toJSON u = object
    [ "prompt_tokens"     .= usagePromptTokens u
    , "completion_tokens" .= usageCompletionTokens u
    , "total_tokens"      .= usageTotalTokens u
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
  } deriving (Show, Eq)

-- | One assistant turn from a function-calling request.
data ChatTurn = ChatTurn
  { ctContent   :: Text
  , ctToolCalls :: [ToolCall]
  , ctUsage     :: Maybe Usage
  , ctError     :: Maybe Text
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
  | ChatTool Text Text             -- ^ tool_call_id, result content
  deriving (Show, Eq)

instance ToJSON ToolSpec where
  toJSON ts = object
    [ "type" .= ("function" :: Text)
    , "function" .= object
        [ "name" .= tsName ts
        , "description" .= tsDescription ts
        , "parameters" .= tsParameters ts
        ]
    ]

instance FromJSON ToolSpec where
  parseJSON = withObject "ToolSpec" $ \v -> do
    fn <- v .: "function"
    ToolSpec <$> fn .: "name" <*> fn .: "description" <*> fn .: "parameters"

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
      "assistant" -> ChatAssistant <$> v .: "content" <*> v .:? "tool_calls" .!= []
      "tool"      -> ChatTool <$> v .: "tool_call_id" <*> v .: "content"
      _           -> fail "Invalid chat role"
