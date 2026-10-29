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

import Control.Concurrent (forkIO, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, withMVar)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_)
import Control.Exception (IOException, SomeException, try)
import Control.Monad (forM_, void)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Infrastructure.Sandbox.Audit (AuditEvent(..), AuditKind(..), appendAudit)
import Infrastructure.Sandbox.Backend
import Infrastructure.Sandbox.Cgroup
  ( CgroupSupport, PidsCgroup, addProcessTo, createPidsCgroup
  , destroyPidsCgroup, detectCgroup )
import Infrastructure.Sandbox.Error
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Policy (AbsolutePath(..), Enforcement(..), ResourceLimits(..))
import Infrastructure.Sandbox.Protocol
import Infrastructure.Sandbox.Scope
import System.Exit (ExitCode(..))
import System.IO (Handle, hClose, hFlush, hIsEOF)
import System.Process
  ( CreateProcess(..), ProcessHandle, StdStream(..), createProcess, getPid
  , interruptProcessGroupOf, proc, terminateProcess, waitForProcess )
import System.Posix.Types (CPid(..))
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
--
-- Exec no longer blocks the frame loop: the child runs on its own thread and
-- its stdin handle is registered so that @stdin@ frames can feed it. That is
-- what makes a persistent interactive shell (scheduler @terminal_open@) work
-- through the same protocol as one-shot commands.
runRunner :: RunnerConfig -> Backend -> BackendCapabilities -> Scope -> IO ()
runRunner cfg backend caps scope = do
  sessions <- newMVar Map.empty
  -- cgroup support is probed once per runner: pids limits are per cgroup,
  -- unlike RLIMIT_NPROC (see ADR-008).
  cgroupSupport <- detectCgroup
  handshake <- readFrame (rcInput cfg)
  case handshake of
    Right Hello{} -> do
      writeFrame (rcOutput cfg) Ready
        { readyBackend = unBackendId (bcBackend caps)
        , readyEnforcement = T.pack (show (bcEnforcement caps))
        , readyCapabilities = Aeson.toJSON (map show (Set.toList (bcCapabilities caps)))
        , readyPid = 0
        }
      loop sessions cgroupSupport
    _ -> writeFrame (rcOutput cfg)
      (Error Nothing "protocol" "expected a hello frame")
  where
    out = rcOutput cfg
    loop sessions cgSupport = do
      frame <- readFrame (rcInput cfg)
      case frame of
        Right Shutdown -> shutdownAll sessions
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
            Right plan ->
              runExec sessions cgSupport scope caps (rcExperiment cfg) out cid request plan mstdin
          loop sessions cgSupport
        Right (Stdin cid payload) -> do
          writeStdin sessions cid payload
          loop sessions cgSupport
        Right _ -> loop sessions cgSupport
        Left err -> writeFrame out (Error Nothing "protocol" (T.pack (show err)))

renderError :: SandboxError -> Text
renderError err = case err of
  SandboxUnavailable bid msg -> "sandbox unavailable (" <> T.pack (show bid) <> "): " <> msg
  PolicyRejected msg -> "policy rejected: " <> msg
  RenderFailed msg -> "render failed: " <> msg
  LaunchFailed msg -> "launch failed: " <> msg
  ProbeFailed results -> "probe failed: " <> T.pack (show results)

-- | Apply the scope's pids limit with cgroup v2 and return it for cleanup.
--
-- A missing or unwritable cgroup is not fatal: the command still runs and the
-- degradation is recorded in the audit log (and shows up in @sandbox status@).
applyPidsLimit
  :: Text
  -> ResourceLimits
  -> Either Text CgroupSupport
  -> Scope
  -> BackendCapabilities
  -> Maybe Text
  -> ProcessHandle
  -> IO (Maybe PidsCgroup)
applyPidsLimit cid limits support scope caps experiment ph =
  case (rlPids limits, support) of
    (n, Right s) | n > 0 -> do
      created <- createPidsCgroup s cid n
      case created of
        Left e -> do
          record scope caps experiment AuditError
            ("pids=" <> T.pack (show n) <> " unavailable: " <> e)
          pure Nothing
        Right cg -> do
          mp <- getPid ph
          case mp of
            Nothing -> pure (Just cg)
            Just (CPid p) -> do
              joined <- addProcessTo cg (fromIntegral p)
              case joined of
                Left e -> record scope caps experiment AuditError
                  ("cgroup join failed: " <> e)
                Right () -> record scope caps experiment AuditAllow
                  ("pids=" <> T.pack (show n))
              pure (Just cg)
    (n, Left reason) | n > 0 -> do
      record scope caps experiment AuditError
        ("pids=" <> T.pack (show n) <> " skipped: " <> reason)
      pure Nothing
    _ -> pure Nothing

-- | A running child whose stdin can still be fed by later @stdin@ frames.
data Session = Session
  { ssStdin   :: Handle
  , ssProcess :: ProcessHandle
  }

writeHandle :: Handle -> Text -> IO ()
writeHandle h payload =
  void (try (BS.hPut h (TE.encodeUtf8 payload) >> hFlush h) :: IO (Either IOException ()))

-- | Route a @stdin@ frame to a running exec. Unknown ids are ignored: the
-- child may already have exited and been reaped.
writeStdin :: MVar (Map.Map Text Session) -> Text -> Text -> IO ()
writeStdin sessions cid payload = do
  running <- readMVar sessions
  maybe (pure ()) (\s -> writeHandle (ssStdin s) payload) (Map.lookup cid running)

-- | On shutdown, stop every child still running in this scope.
shutdownAll :: MVar (Map.Map Text Session) -> IO ()
shutdownAll sessions = do
  running <- modifyMVar sessions (\m -> pure (Map.empty, m))
  forM_ (Map.elems running) $ \s -> do
    _ <- try (terminateProcess (ssProcess s)) :: IO (Either SomeException ())
    _ <- try (hClose (ssStdin s)) :: IO (Either IOException ())
    pure ()

runExec :: MVar (Map.Map Text Session) -> Either Text CgroupSupport -> Scope -> BackendCapabilities -> Maybe Text -> Handle -> Text -> LaunchRequest -> LaunchPlan -> Maybe Text -> IO ()
runExec sessions cgSupport scope caps experiment out cid request plan initialStdin = case lpArgv plan of
  [] -> writeFrame out (Error (Just cid) "backend" "empty argv")
  (cmd : args) -> do
    record scope caps experiment AuditAllow
      ("exec " <> T.intercalate " " (lrArgv request))
    started <- try $ createProcess (proc (T.unpack cmd) (map T.unpack args))
      { cwd = Just (unAbsolutePath (lrCwd request))
      , env = Just [(T.unpack k, T.unpack v) | (k, v) <- lrEnv request]
      , std_in = CreatePipe
      , std_out = CreatePipe
      , std_err = CreatePipe
      , create_group = True
      }
    case started of
      Left (e :: SomeException) ->
        writeFrame out (Error (Just cid) "backend" ("spawn failed: " <> T.pack (show e)))
      Right (mIn, mOut, mErr, ph) -> do
        -- pids limit via cgroup v2 (ADR-008). Probed once at startup; an
        -- unusable cgroup degrades to "no limit" and records why.
        cgroup <- applyPidsLimit cid (lpLimits plan) cgSupport scope caps experiment ph
        lock <- newMVar ()
        outDone <- newEmptyMVar
        errDone <- newEmptyMVar
        case mIn of
          Just h -> do
            modifyMVar_ sessions (pure . Map.insert cid (Session h ph))
            maybe (pure ()) (writeHandle h) initialStdin
          Nothing -> pure ()
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
        -- 等待与收帧分离：主循环必须继续读 stdin，交互式 shell 才可用。
        _ <- forkIO $ do
          exit <- waitWithTimeout (lrTimeoutMs request) ph
          takeMVar outDone
          takeMVar errDone
          writeFrame out Exit
            { exitId = cid
            , exitCode = exitCodeOf exit
            , exitSignal = Nothing
            }
          modifyMVar_ sessions (pure . Map.delete cid)
          case mIn of
            Just h -> void (try (hClose h) :: IO (Either IOException ()))
            Nothing -> pure ()
          maybe (pure ()) destroyPidsCgroup cgroup
          record scope caps experiment
            (if exitCodeOf exit == 0 then AuditAllow else AuditError)
            ("exit " <> T.pack (show (exitCodeOf exit)))
        pure ()

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
    -- 按块而不是按行读：交互式 shell 的提示符（`bash-5.2$ `）没有换行，
    -- hGetLine 会把它一直憋到下一次输出。
    go = do
      chunk <- try (BS.hGetSome handle 4096) :: IO (Either IOException BS.ByteString)
      case chunk of
        Left _ -> pure ()
        Right bs
          | BS.null bs -> pure ()
          | otherwise -> do
              let text = TE.decodeUtf8With TEE.lenientDecode bs
              withMVar lock $ \_ -> writeFrame out (mkFrame text)
              -- deny 匹配仍按行做，避免把整块 stderr 当成一个 target
              maybe (pure ()) (\f -> mapM_ f (T.lines text)) onLine
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

