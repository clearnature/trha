{-# LANGUAGE OverloadedStrings #-}

module Core.Agent.Types
  ( Agent(..)
  , AgentState(..)
  , AgentId
  , StepId
  , ToolCallId
  , ErrorType(..)
  , Message(..)
  , Result(..)
  , AgentConfig(..)
  ) where

import Control.Concurrent.STM
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import qualified Data.Text as T

-- | Unique identifier for an agent
type AgentId = String

-- | Unique identifier for a step
type StepId = String

-- | Unique identifier for a tool call
type ToolCallId = String

-- | Error types that can occur
data ErrorType
  = ToolError String
  | LLMError String
  | TimeoutError
  | InterruptedError
  deriving (Show, Eq)

-- | A message in the conversation
data Message = Message
  { messageRole    :: Text
  , messageContent :: Text
  } deriving (Show, Eq)

-- | Result of an agent run
data Result = Result
  { resultText   :: Text
  , resultTokens :: Int
  } deriving (Show, Eq)

-- | States of an agent
data AgentState
  = Idle
  | Processing StepId
  | WaitingForTool ToolCallId
  | Completed Result
  | Error ErrorType
  deriving (Show, Eq)

-- | Agent configuration
data AgentConfig = AgentConfig
  { configModel    :: Text
  , configMaxSteps :: Int
  , configTimeout  :: Int
  } deriving (Show, Eq)

-- | An agent with its state and inbox
data Agent = Agent
  { agentId     :: AgentId
  , agentState  :: TVar AgentState
  , agentInbox  :: TQueue Message
  , agentConfig :: AgentConfig
  }

--------------------------------------------------------------------------------
-- JSON instances for the persistable subset.
--
-- Only what survives a kernel restart is encoded: the FSM state (and the
-- values it can carry). Dynamic projections and events stay in memory — they
-- are derived state and are recomputed on the next step.
--------------------------------------------------------------------------------

instance ToJSON ErrorType where
  toJSON (ToolError m)    = object ["kind" .= ("tool"    :: Text), "message" .= m]
  toJSON (LLMError m)     = object ["kind" .= ("llm"     :: Text), "message" .= m]
  toJSON TimeoutError     = object ["kind" .= ("timeout" :: Text)]
  toJSON InterruptedError = object ["kind" .= ("interrupted" :: Text)]

instance FromJSON ErrorType where
  parseJSON = withObject "ErrorType" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "tool"        -> ToolError <$> o .: "message"
      "llm"         -> LLMError <$> o .: "message"
      "timeout"     -> pure TimeoutError
      "interrupted" -> pure InterruptedError
      other         -> fail ("unknown error kind: " <> T.unpack other)

instance ToJSON Result where
  toJSON r = object ["text" .= resultText r, "tokens" .= resultTokens r]

instance FromJSON Result where
  parseJSON = withObject "Result" $ \o ->
    Result <$> o .: "text" <*> o .: "tokens"

instance ToJSON AgentState where
  toJSON Idle = object ["state" .= ("idle" :: Text)]
  toJSON (Processing sid) = object ["state" .= ("processing" :: Text), "step" .= sid]
  toJSON (WaitingForTool cid) = object ["state" .= ("waiting_for_tool" :: Text), "call" .= cid]
  toJSON (Completed r) = object ["state" .= ("completed" :: Text), "result" .= r]
  toJSON (Error e) = object ["state" .= ("error" :: Text), "error" .= e]

instance FromJSON AgentState where
  parseJSON = withObject "AgentState" $ \o -> do
    st <- o .: "state" :: Parser Text
    case st of
      "idle"             -> pure Idle
      "processing"       -> Processing <$> o .: "step"
      "waiting_for_tool" -> WaitingForTool <$> o .: "call"
      "completed"        -> Completed <$> o .: "result"
      "error"            -> Error <$> o .: "error"
      other              -> fail ("unknown agent state: " <> T.unpack other)