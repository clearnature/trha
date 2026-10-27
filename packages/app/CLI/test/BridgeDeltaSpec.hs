{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The SSE subscription contract (M0, tui-port-plan task 2):
-- one /api/events stream carries tool progress AND assistant text deltas;
-- 'subscribeSessionEventsWith' must route them to their own sinks. The delta
-- sink is what the TUI (and, on the same contract, the Desktop/Web shells) use
-- to stream the answer while it is generated.
--
-- Uses a raw-socket SSE fixture (no live scheduler needed).
module BridgeDeltaSpec (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Monad (when)
import Control.Concurrent.MVar
import Control.Exception (SomeException, catch, throwIO)
import qualified Data.ByteString.Char8 as BC
import Network.Socket
import Network.Socket.ByteString (send, recv, sendAll)
import System.Timeout (timeout)
import Test.Hspec

import Bridge.Scheduler
    ( createSchedulerBridge, subscribeSessionEventsWith
    , subscribeSessionEventsWithTerminal )
import Core.Types (CLIConfig(..), ToolEvent(..), ToolRunStatus(..), defaultCLIConfig)

spec :: Spec
spec = describe "Bridge.Scheduler.subscribeSessionEvents" $ do
  it "routes tool progress and text deltas to their own sinks" $
    withSseServer sseBody $ \port -> do
      bridge <- createSchedulerBridge testConfig { configPort = port }
      toolVar <- newEmptyMVar
      deltaVar <- newEmptyMVar
      cancel <- subscribeSessionEventsWith bridge "s1"
                  (putMVar toolVar) (putMVar deltaVar)
      tool <- getWithin 3000000 toolVar
      delta <- getWithin 3000000 deltaVar
      cancel `catch` \(_ :: SomeException) -> return ()
      delta `shouldBe` "Hello"
      fmap teName tool `shouldBe` Right "bash"

  it "reports the assistant echo as the turn's terminal marker" $
    withSseServer sseTerminalBody $ \port -> do
      bridge <- createSchedulerBridge testConfig { configPort = port }
      doneVar <- newEmptyMVar
      cancel <- subscribeSessionEventsWithTerminal bridge "s2"
                  (const (return ())) (const (return ())) (putMVar doneVar ()) (const (return ()))
      _ <- getWithin 3000000 doneVar
      cancel `catch` \(_ :: SomeException) -> return ()
      pure ()
  where
    testConfig = defaultCLIConfig
      { configHost = "127.0.0.1", configToken = "test-token"
      , configTimeout = 3000, configProxy = ""
      -- the fixture below is a plain TCP socket, not TLS
      , configScheme = "http" }

    -- One tool event, then one text delta — the two shapes the shells care about.
    sseBody = BC.concat
      [ "data: {\"name\":\"bash\",\"status\":\"succeeded\"}\n\n"
      , "data: {\"text\":\"Hello\"}\n\n" ]

    -- A turn's tail: tool progress, then the assistant message echo.
    sseTerminalBody = BC.concat
      [ "data: {\"name\":\"bash\",\"status\":\"succeeded\"}\n\n"
      , "data: {\"role\":\"user\",\"content\":\"go\"}\n\n"
      , "data: {\"role\":\"assistant\",\"content\":\"done\"}\n\n" ]

    getWithin us var = do
      r <- timeout us (takeMVar var)
      maybe (fail "timeout waiting for SSE sink") pure r

-- | One-shot loopback SSE fixture: accept exactly one connection, read the
-- request head, write the canned SSE body, close.
withSseServer :: BC.ByteString -> (Int -> IO a) -> IO a
withSseServer body action = do
  sock <- socket AF_INET Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  bind sock (SockAddrInet 0 0)
  listen sock 1
  SockAddrInet portNum _ <- getSocketName sock
  let port = fromIntegral portNum :: Int
  done <- newEmptyMVar
  tid <- forkIO (serve sock done)
  r <- action port
  _ <- takeMVar done
  killThread tid `catch` \(_ :: SomeException) -> return ()
  close sock
  pure r
  where
    serve sock done = do
      (conn, _) <- accept sock
      _ <- readHead conn
      sendAll conn (BC.concat
        [ "HTTP/1.1 200 OK\r\n"
        , "Content-Type: text/event-stream\r\n"
        , "Connection: close\r\n\r\n" ])
      sendAll conn body
      close conn
      putMVar done ()
      `catch` \(_ :: SomeException) -> putMVar done ()
    sendAll c bytes = do
      sent <- send c bytes -- Network.Socket.ByteString.send
      when (sent < BC.length bytes) $ sendAll c (BC.drop sent bytes)
    readHead conn = do
      chunk <- recv conn 4096
      if BC.null chunk || "\r\n\r\n" `BC.isInfixOf` chunk
        then return ()
        else readHead conn
