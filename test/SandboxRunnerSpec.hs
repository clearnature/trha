{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | End-to-end tests for the runner (T1.4): handshake, streaming frames,
-- exit codes, timeout and fail-closed policy errors. Uses real pipes and a
-- real bwrap process; skipped when bwrap is unavailable.
module SandboxRunnerSpec (sandboxRunnerSpec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, finally, onException, try)
import Data.Text (Text)
import qualified Data.Text as T
import Infrastructure.Sandbox
import Infrastructure.Sandbox.Backend (BackendCapabilities(..))
import qualified Infrastructure.Sandbox.Backend.Linux as Linux
import Infrastructure.Sandbox.Protocol
import Infrastructure.Sandbox.Runner
import System.Directory
  ( createDirectoryIfMissing, getHomeDirectory, removeDirectoryRecursive )
import System.FilePath ((</>))
import System.IO (BufferMode(..), Handle, hSetBuffering)
import System.Posix.IO (createPipe, fdToHandle)
import System.Timeout (timeout)
import Test.Hspec

sandboxRunnerSpec :: Spec
sandboxRunnerSpec = describe "runner end-to-end (T1.4)" $ do
  it "handshakes, streams output and returns exit codes" $ do
    caps <- requireBwrap
    withRunner caps $ \ws hIn hOut -> do
      writeFrame hIn (Hello "s" Nothing "workspace-write" "process")
      handshake <- readFrame hOut
      handshake `shouldSatisfy` isReady

      writeFrame hIn (Exec "c1" ["echo", "hello"] (T.pack ws) [] Nothing (Just 5000))
      first <- collect hOut "c1"
      stdoutOf first `shouldSatisfy` T.isInfixOf "hello"
      exitOf first `shouldBe` 0

      writeFrame hIn (Exec "c2" ["sh", "-c", "exit 3"] (T.pack ws) [] Nothing (Just 5000))
      second <- collect hOut "c2"
      exitOf second `shouldBe` 3

  it "kills a command that exceeds its timeout" $ do
    caps <- requireBwrap
    withRunner caps $ \ws hIn hOut -> do
      writeFrame hIn (Hello "s" Nothing "workspace-write" "process")
      _ <- readFrame hOut
      writeFrame hIn (Exec "slow" ["sleep", "5"] (T.pack ws) [] Nothing (Just 200))
      frames <- collect hOut "slow"
      exitOf frames `shouldBe` 124

  it "emits a deny frame for a blocked write (T1.7)" $ do
    caps <- requireBwrap
    withRunner caps $ \ws hIn hOut -> do
      writeFrame hIn (Hello "s" Nothing "workspace-write" "process")
      _ <- readFrame hOut
      writeFrame hIn (Exec "d1" ["sh", "-c", "touch /etc/trha-deny-probe"]
        (T.pack ws) [] Nothing (Just 5000))
      frames <- collect hOut "d1"
      frames `shouldSatisfy` any isDeny
      exitOf frames `shouldSatisfy` (/= 0)

  it "reports policy errors without spawning" $ do
    caps <- requireBwrap
    let noSandbox = caps { bcEnforcement = None "test: no sandbox" }
    withRunner noSandbox $ \ws hIn hOut -> do
      writeFrame hIn (Hello "s" Nothing "workspace-write" "process")
      _ <- readFrame hOut
      writeFrame hIn (Exec "e1" ["echo", "x"] (T.pack ws) [] Nothing Nothing)
      frame <- readFrame hOut
      frame `shouldSatisfy` isError

-- Helpers ---------------------------------------------------------------

withRunner :: BackendCapabilities -> (FilePath -> Handle -> Handle -> IO a) -> IO a
withRunner caps action = do
  ws <- prepareWorkspace
  (inR, inW) <- createPipe
  (outR, outW) <- createPipe
  hIn <- fdToHandle inR
  hInW <- fdToHandle inW
  hOut <- fdToHandle outR
  hOutW <- fdToHandle outW
  hSetBuffering hInW NoBuffering
  hSetBuffering hOut LineBuffering
  done <- newEmptyMVar
  let scope = scopeRoot (ScopeId "runner")
        (WorkspaceWrite WritableRoot
          { wrRoot = AbsolutePath ws
          , wrScratch = ExclusivePath (AbsolutePath ws)
          , wrReadOnly = []
          , wrNetwork = NetworkOff
          , wrLimits = defaultResourceLimits
          })
        (ExclusivePath (AbsolutePath ws))
  _ <- forkIO $
    runRunner (RunnerConfig hIn hOutW Nothing) Linux.backend caps scope
      `finally` putMVar done ()
  let shutdown = do
        _ <- try (writeFrame hInW Shutdown) :: IO (Either SomeException ())
        _ <- timeout 5000000 (takeMVar done)
        cleanup ws
  action ws hInW hOut `finally` shutdown

prepareWorkspace :: IO FilePath
prepareWorkspace = do
  home <- getHomeDirectory
  let ws = home </> ".trha-runner-e2e"
  createDirectoryIfMissing True ws
  pure ws

cleanup :: FilePath -> IO ()
cleanup ws = do
  _ <- try (removeDirectoryRecursive ws) :: IO (Either SomeException ())
  pure ()

requireBwrap :: IO BackendCapabilities
requireBwrap = do
  caps <- Linux.probeLinux
  case caps of
    Left (SandboxUnavailable _ msg) ->
      pendingWith ("bwrap unavailable: " ++ show msg) >> fail "unreachable"
    Left e -> expectationFailure (show e) >> fail "unreachable"
    Right c -> pure c

isReady :: Either ProtocolError Frame -> Bool
isReady (Right Ready{}) = True
isReady _ = False

isDeny :: Frame -> Bool
isDeny Deny{} = True
isDeny _ = False

isError :: Either ProtocolError Frame -> Bool
isError (Right Error{}) = True
isError _ = False

collect :: Handle -> Text -> IO [Frame]
collect handle cid = go []
  where
    go acc = do
      frame <- readFrame handle
      case frame of
        Right f@(Stdout i _) | i == cid -> go (f : acc)
        Right f@(Stderr i _) | i == cid -> go (f : acc)
        Right f@(Deny i _ _) | i == cid -> go (f : acc)
        Right f@(Exit i _ _) | i == cid -> pure (reverse (f : acc))
        Right _ -> go acc
        Left err -> fail ("protocol error: " ++ show err)

stdoutOf :: [Frame] -> Text
stdoutOf frames = T.concat [d | Stdout _ d <- frames]

exitOf :: [Frame] -> Int
exitOf frames = case [c | Exit _ c _ <- frames] of
  (c : _) -> c
  [] -> -1
