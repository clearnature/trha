{-# LANGUAGE OverloadedStrings #-}

module Core.Network
  ( -- * Network Base
    NetworkConfig(..)
  , createNetworkConfig
  
    -- * TCP
  , tcpConnect
  , tcpListen
  , tcpAccept
  
    -- * UDP
  , udpConnect
  , udpListen
  , udpSend
  , udpReceive
  
    -- * Unix Socket
  , unixConnect
  , unixListen
  , unixAccept
  ) where

import Network.Socket
import qualified Network.Socket as NS
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T

-- | Network configuration
data NetworkConfig = NetworkConfig
  { networkHost :: String
  , networkPort :: Int
  }

-- | Create a new network configuration
createNetworkConfig :: String -> Int -> NetworkConfig
createNetworkConfig host port = NetworkConfig host port

-- | TCP connect
tcpConnect :: NetworkConfig -> IO Socket
tcpConnect config = do
    sock <- socket AF_INET Stream 0
    addr <- inet_addr (networkHost config)
    connect sock (SockAddrInet (fromIntegral (networkPort config)) addr)
    return sock

-- | TCP listen
tcpListen :: NetworkConfig -> IO Socket
tcpListen config = do
    sock <- socket AF_INET Stream 0
    addr <- inet_addr (networkHost config)
    bind sock (SockAddrInet (fromIntegral (networkPort config)) addr)
    listen sock 5
    return sock

-- | TCP accept
tcpAccept :: Socket -> IO (Socket, SockAddr)
tcpAccept sock = accept sock

-- | UDP connect
udpConnect :: NetworkConfig -> IO Socket
udpConnect config = do
    sock <- socket AF_INET Datagram 0
    addr <- inet_addr (networkHost config)
    connect sock (SockAddrInet (fromIntegral (networkPort config)) addr)
    return sock

-- | UDP listen
udpListen :: NetworkConfig -> IO Socket
udpListen config = do
    sock <- socket AF_INET Datagram 0
    addr <- inet_addr (networkHost config)
    bind sock (SockAddrInet (fromIntegral (networkPort config)) addr)
    return sock

-- | UDP send
udpSend :: Socket -> BS.ByteString -> IO Int
udpSend sock msg = NS.send sock msg

-- | UDP receive
udpReceive :: Socket -> Int -> IO BS.ByteString
udpReceive sock size = NS.recv sock size

-- | Unix socket connect
unixConnect :: FilePath -> IO Socket
unixConnect path = do
    sock <- socket AF_UNIX Stream 0
    connect sock (SockAddrUnix path)
    return sock

-- | Unix socket listen
unixListen :: FilePath -> IO Socket
unixListen path = do
    sock <- socket AF_UNIX Stream 0
    bind sock (SockAddrUnix path)
    listen sock 5
    return sock

-- | Unix socket accept
unixAccept :: Socket -> IO (Socket, SockAddr)
unixAccept sock = accept sock