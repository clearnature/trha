{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Core.Server
  ( -- * Server
    SDKServer(..)
  , createServer
  , startServer
  
    -- * API
  , API
  , api
  ) where

import Core.Types
import Core.Handlers
import Servant
import Network.Wai
import Network.Wai.Handler.Warp
import Data.Text (Text)

-- | SDK server
data SDKServer = SDKServer
  { serverPort :: Int
  , serverHost :: Text
  }

-- | Create a new SDK server
createServer :: Int -> Text -> SDKServer
createServer port host = SDKServer port host

-- | Start the server
startServer :: SDKServer -> IO ()
startServer server = do
  let port = serverPort server
  let host = serverHost server
  putStrLn $ "Starting SDK server on " ++ show host ++ ":" ++ show port
  run port (serve api handlers)

-- | API type
type API =
  -- Session endpoints
  "api" :> "sessions" :> Get '[JSON] [SessionId]
  :<|> "api" :> "sessions" :> ReqBody '[JSON] () :> Post '[JSON] SessionId
  :<|> "api" :> "sessions" :> Capture "id" SessionId :> Get '[JSON] SessionEvent
  :<|> "api" :> "sessions" :> Capture "id" SessionId :> Delete '[JSON] ()
  
  -- Message endpoints
  :<|> "api" :> "sessions" :> Capture "id" SessionId :> "messages" :> Get '[JSON] [Message]
  :<|> "api" :> "sessions" :> Capture "id" SessionId :> "messages" :> ReqBody '[JSON] Message :> Post '[JSON] StreamChunk
  
  -- Agent endpoints
  :<|> "api" :> "agents" :> Capture "id" AgentId :> Get '[JSON] AgentState
  :<|> "api" :> "agents" :> Capture "id" AgentId :> ReqBody '[JSON] AgentState :> Put '[JSON] ()
  
  -- Tool endpoints
  :<|> "api" :> "tools" :> Get '[JSON] [Tool]
  :<|> "api" :> "tools" :> ReqBody '[JSON] Tool :> Post '[JSON] ()
  :<|> "api" :> "tools" :> Capture "name" ToolName :> Delete '[JSON] ()
  
  -- Model endpoints
  :<|> "api" :> "models" :> Get '[JSON] [ModelInfo]
  :<|> "api" :> "models" :> Capture "name" Text :> Get '[JSON] ModelInfo
  
  -- Health endpoint
  :<|> "api" :> "health" :> Get '[JSON] Bool

-- | API proxy
api :: Proxy API
api = Proxy

-- | Handlers
handlers :: Server API
handlers =
  listSessionsHandler
  :<|> createSessionHandler
  :<|> getSessionHandler
  :<|> deleteSessionHandler
  :<|> getMessagesHandler
  :<|> sendMessageHandler
  :<|> getAgentStateHandler
  :<|> updateAgentStateHandler
  :<|> listToolsHandler
  :<|> registerToolHandler
  :<|> unregisterToolHandler
  :<|> listModelsHandler
  :<|> getModelHandler
  :<|> healthCheckHandler