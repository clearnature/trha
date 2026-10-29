{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Runner: line-delimited frame IO plus the P1 execution loop (T1.4).
--
-- The runner is the only process boundary. It reads @hello@, answers
-- @ready@, then executes @exec@ frames through the backend's pure renderer.
-- Any failure is reported as an @error@ frame; there is no unconfined
-- fallback.
module Infrastructure.Sandbox.Runner
  ( RunnerConfig(..)
  , readFrame
  , writeFrame
  , runRunner
  ) where

import Control.Concurrent (forkIO, newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Concurrent.MVar (MVar)
import Control.Exception (IOException, SomeException, try)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Infrastructure.Sandbox.Audit (AuditEvent(..), AuditKind(..), appendAudit)
import Infrastructure.Sandbox.Backend
import Infrastructure.Sandbox.Error
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Policy (AbsolutePath(..), Enforcement(..))
import Infrastructure.Sandbox.Protocol
import Infrastructure.Sandbox.Scope
import System.Exit (ExitCode(..))
import System.IO (Handle, hFlush, hIsEOF)
import System.Process
  ( CreateProcess(..), ProcessHandle, StdStream(..), createProcess
  , interruptProcessGroupOf, proc, terminateProcess, waitForProcess )
import System.Timeout (timeout)

data RunnerConfig = RunnerConfig
  { rcInput      :: Handle
  , rcOutput     :: Handle
  , rcExperiment :: Maybe Text
  }

readFrame :: Handle -> IO (Either ProtocolError Frame)
readFrame handle = do
  eof <- hIsEOF handle
  if eof
    then pure (Left (MalformedFrame "eof before a frame"))
    else do
      line <- BC.hGetLine handle
      pure (decodeFrame line)

writeFrame :: Handle -> Frame -> IO ()
writeFrame handle frame = do
  BS.hPut handle (BL.toStrict (encodeFrame frame <> "\n"))
  hFlush handle

-- | Handshake, then serve exec frames until shutdown/EOF.
runRunner :: RunnerConfig -> Backend -> BackendCapabilities -> Scope -> IO ()
runRunner cfg backend caps scope = do
  handshake <- readFrame (rcInput cfg)
  case handshake of
    Right Hello{} -> do
      writeFrame (rcOutput cfg) Ready
        { readyBackend = unBackendId (bcBackend caps)
        , readyEnforcement = T.pack (show (bcEnforcement caps))
        , readyCapabilities = Aeson.toJSON (map show (Set.toList (bcCapabilities caps)))
        , readyPid = 0
        }
      loop
    _ -> writeFrame (rcOutput cfg)
      (Error Nothing "protocol" "expected a hello frame")
  where
    out = rcOutput cfg
    loop = do
      frame <- readFrame (rcInput cfg)
      case frame of
        Right Shutdown -> pure ()
        Right (Exec cid argv cwd env mstdin mtimeout) -> do
          let request = LaunchRequest
                { lrArgv = argv
                , lrCwd = AbsolutePath (T.unpack cwd)
                , lrEnv = env
                , lrStdin = StdinClosed
                , lrTimeoutMs = mtimeout
                }
          case planWith backend caps scope request of
            Left err -> writeFrame out (Error (Just cid) "policy" (renderError err))
            Right plan -> runExec scope caps (rcExperiment cfg) out cid request plan
          loop
        Right _ -> loop
        Left err -> writeFrame out (Error Nothing "protocol" (T.pack (show err)))

renderError :: SandboxError -> Text
renderError err = case err of
  SandboxUnavailable bid msg -> "sandbox unavailable (" <> T.pack (show bid) <> "): " <> msg
  PolicyRejected msg -> "policy rejected: " <> msg
  RenderFailed msg -> "render failed: " <> msg
  LaunchFailed msg -> "launch failed: " <> msg
  ProbeFailed results -> "probe failed: " <> T.pack (show results)

runExec :: Scope -> BackendCapabilities -> Maybe Text -> Handle -> Text -> LaunchRequest -> LaunchPlan -> IO ()
runExec scope caps experiment out cid request plan = case lpArgv plan of
  [] -> writeFrame out (Error (Just cid) "backend" "empty argv")
  (cmd : args) -> do
    record scope caps experiment AuditAllow
      ("exec " <> T.intercalate " " (lrArgv request))
    started <- try $ createProcess (proc (T.unpack cmd) (map T.unpack args))
      { cwd = Just (unAbsolutePath (lrCwd request))
      , env = Just [(T.unpack k, T.unpack v) | (k, v) <- lrEnv request]
      , std_in = NoStream
      , std_out = CreatePipe
      , std_err = CreatePipe
      , create_group = True
      }
    case started of
      Left (e :: SomeException) ->
        writeFrame out (Error (Just cid) "backend" ("spawn failed: " <> T.pack (show e)))
      Right (_, mOut, mErr, ph) -> do
        lock <- newMVar ()
        outDone <- newEmptyMVar
        errDone <- newEmptyMVar
        case mOut of
          Just h -> do
            _ <- forkIO $ drain lock out (Stdout cid) Nothing h >> putMVar outDone ()
            pure ()
          Nothing -> putMVar outDone ()
        case mErr of
          Just h -> do
            _ <- forkIO $ drain lock out (Stderr cid)
                   (Just (denySink scope caps experiment out cid)) h >> putMVar errDone ()
            pure ()
          Nothing -> putMVar errDone ()
        exit <- waitWithTimeout (lrTimeoutMs request) ph
        takeMVar outDone
        takeMVar errDone
        writeFrame out Exit
          { exitId = cid
          , exitCode = exitCodeOf exit
          , exitSignal = Nothing
          }
        record scope caps experiment
          (if exitCodeOf exit == 0 then AuditAllow else AuditError)
          ("exit " <> T.pack (show (exitCodeOf exit)))

-- | Audit writes are best-effort: a full disk must not fail the command.
record :: Scope -> BackendCapabilities -> Maybe Text -> AuditKind -> Text -> IO ()
record scope caps experiment kind target = do
  let event = AuditEvent
        { aeTs = ""
        , aeScope = unScopeId (scId scope)
        , aeKind = kind
        , aeTarget = target
        , aeBackend = unBackendId (bcBackend caps)
        , aeEnforcement = T.pack (show (bcEnforcement caps))
        , aeExperiment = experiment
        }
  _ <- try (appendAudit event) :: IO (Either SomeException ())
  pure ()

waitWithTimeout :: Maybe Int -> ProcessHandle -> IO ExitCode
waitWithTimeout (Just ms) ph = do
  waited <- timeout (fromIntegral ms * 1000) (waitForProcess ph)
  case waited of
    Just code -> pure code
    Nothing -> do
      _ <- try (terminateProcess ph) :: IO (Either SomeException ())
      _ <- try (interruptProcessGroupOf ph) :: IO (Either SomeException ())
      _ <- waitForProcess ph
      pure (ExitFailure 124)
waitWithTimeout Nothing ph = waitForProcess ph

exitCodeOf :: ExitCode -> Int
exitCodeOf ExitSuccess = 0
exitCodeOf (ExitFailure code) = code

drain :: MVar () -> Handle -> (Text -> Frame) -> Maybe (Text -> IO ()) -> Handle -> IO ()
drain lock out mkFrame onLine handle = go
  where
    go = do
      chunk <- try (BC.hGetLine handle) :: IO (Either IOException BS.ByteString)
      case chunk of
        Left _ -> pure ()
        Right line -> do
          let text = TE.decodeUtf8With TEE.lenientDecode line
          withMVar lock $ \_ -> writeFrame out (mkFrame text)
          maybe (pure ()) ($ text) onLine
          go

-- | Turn a bwrap refusal on stderr into a structured 'Deny' frame plus an
-- audit event.  Without this, refusals only exist as stderr text and the
-- scheduler/audit log never see them.
denySink :: Scope -> BackendCapabilities -> Maybe Text -> Handle -> Text -> Text -> IO ()
denySink scope caps experiment out cid line =
  case [ kind | (kind, pat) <- patterns, pat `T.isInfixOf` line ] of
    (kind : _) -> do
      let target = T.strip line
      writeFrame out Deny { denyId = cid, denyKind = kind, denyTarget = target }
      record scope caps experiment AuditDeny target
    [] -> pure ()
  where
    patterns =
      [ ("fs-write", "Read-only file system")
      , ("fs-read", "Permission denied")
      , ("syscall", "Operation not permitted")
      , ("net", "Network is unreachable")
      , ("net", "Could not resolve host")
      ]

