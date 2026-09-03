{-# LANGUAGE OverloadedStrings #-}

module Client.Session
  ( -- * Session Client
    SessionClient(..)
  , createSessionClient
  
    -- * Session Operations
  , create
  , list
  , get
  , delete
  
    -- * Message Operations
  , sendMessage
  , getMessages
  , streamMessages
  ) where

import Core.Types
import Core.Client
import Core.HTTP
import Data.Text (Text)

-- | Session client
data SessionClient = SessionClient
  { sessionClientSDK :: SDKClient
  }

-- | Create a new session client
createSessionClient :: SDKClient -> SessionClient
createSessionClient sdk = SessionClient sdk

-- | Create a new session
create :: SessionClient -> IO (Either SDKError SessionId)
create client = createSession (sessionClientSDK client)

-- | List all sessions
list :: SessionClient -> IO (Either SDKError [SessionId])
list client = listSessions (sessionClientSDK client)

-- | Get a session by ID
get :: SessionClient -> SessionId -> IO (Either SDKError SessionEvent)
get client sessionId = getSession (sessionClientSDK client) sessionId

-- | Delete a session
delete :: SessionClient -> SessionId -> IO (Either SDKError ())
delete client sessionId = deleteSession (sessionClientSDK client) sessionId

-- | Send a message to a session
sendMessage :: SessionClient -> SessionId -> Text -> IO (Either SDKError StreamChunk)
sendMessage client sessionId content = 
  Core.Client.sendMessage (sessionClientSDK client) sessionId content

-- | Get messages from a session
getMessages :: SessionClient -> SessionId -> IO (Either SDKError [Message])
getMessages client sessionId = 
  Core.Client.getMessages (sessionClientSDK client) sessionId

-- | Stream messages from a session
streamMessages :: SessionClient -> SessionId -> (StreamChunk -> IO ()) -> IO (Either SDKError ())
streamMessages client sessionId callback = 
  Core.Client.streamMessages (sessionClientSDK client) sessionId callback