{-# LANGUAGE OverloadedStrings #-}

module Core.Socket
  ( -- * Socket Base
    SocketConfig(..)
  , createSocketConfig
  
    -- * Non-blocking I/O
  , nonBlockingConnect
  , nonBlockingListen
  , nonBlockingAccept
  
    -- * Socket Options
  , setSocketOption
  , getSocketOption
  
    -- * Socket Operations
  , socketSend
  , socketReceive
  , socketClose
  ) where

import Network.Socket
import qualified Network.Socket as NS
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T

-- | Socket configuration
data SocketConfig = SocketConfig
  { socketHost :: String
  , socketPort :: Int
  , socketNonBlocking :: Bool
  }

-- | Create a new socket configuration
createSocketConfig :: String -> Int -> Bool -> SocketConfig
createSocketConfig host port nonBlocking = SocketConfig host port nonBlocking

-- | Non-blocking connect
nonBlockingConnect :: SocketConfig -> IO Socket
nonBlockingConnect config = do
    sock <- socket AF_INET Stream 0
    when (socketNonBlocking config) $
        NS.setSocketOption sock NonBlockingRead 1
    addr <- inet_addr (socketHost config)
    connect sock (SockAddrInet (fromIntegral (socketPort config)) addr)
    return sock

-- | Non-blocking listen
nonBlockingListen :: SocketConfig -> IO Socket
nonBlockingListen config = do
    sock <- socket AF_INET Stream 0
    when (socketNonBlocking config) $
        NS.setSocketOption sock NonBlockingRead 1
    addr <- inet_addr (socketHost config)
    bind sock (SockAddrInet (fromIntegral (socketPort config)) addr)
    listen sock 5
    return sock

-- | Non-blocking accept
nonBlockingAccept :: Socket -> IO (Socket, SockAddr)
nonBlockingAccept sock = accept sock

-- | Set socket option
setSocketOption :: Socket -> SocketOption -> Int -> IO ()
setSocketOption = NS.setSocketOption

-- | Get socket option
getSocketOption :: Socket -> SocketOption -> IO Int
getSocketOption = NS.getSocketOption

-- | Socket send
socketSend :: Socket -> BS.ByteString -> IO Int
socketSend sock msg = send sock msg

-- | Socket receive
socketReceive :: Socket -> Int -> IO BS.ByteString
socketReceive sock size = recv sock size

-- | Socket close
socketClose :: Socket -> IO ()
socketClose sock = close sock