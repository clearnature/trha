{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
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
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, readMVar)
import Control.Exception (IOException, SomeException, finally, try)
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
import Infrastructure.Sandbox.Error
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Policy (AbsolutePath(..), Enforcement(..))
import Infrastructure.Sandbox.Protocol
import Infrastructure.Sandbox.Scope
import System.Exit (ExitCode(..))
import System.IO (Handle, hClose, hFlush, hIsEOF)
import System.Process
  ( CreateProcess(..), ProcessHandle, StdStream(..), createProcess
  , interruptProcessGroupOf, proc, terminateProcess, waitForProcess )
import System.Timeout (timeout)
#ifdef mingw32_HOST_OS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word32)
import Foreign (Ptr, castPtr)
import qualified Infrastructure.Sandbox.Win32.Acl as W32Acl
import qualified Infrastructure.Sandbox.Win32.AppContainer as W32AC
import qualified Infrastructure.Sandbox.Win32.Job as W32Job
import qualified Infrastructure.Sandbox.Win32.Process as W32Proc
#endif

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
      sessions <- newMVar Map.empty
      loop sessions
    _ -> writeFrame (rcOutput cfg)
      (Error Nothing "protocol" "expected a hello frame")
  where
    out = rcOutput cfg
    loop sessions = do
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
                , lrDenyReads = []
                , lrDenyFiles = []
                }
          case planWith backend caps scope request of
            Left err -> writeFrame out (Error (Just cid) "policy" (renderError err))
            Right plan ->
              runExec sessions scope caps (rcExperiment cfg) out cid request plan mstdin
          loop sessions
        -- terminal_open 走同一条协议：stdin 帧必须路由到仍在运行的子进程，
        -- 否则交互式 shell 只收到握手、收不到命令。
        Right (Stdin cid payload) -> writeStdin sessions cid payload >> loop sessions
        Right _ -> loop sessions
        Left err -> writeFrame out (Error Nothing "protocol" (T.pack (show err)))

renderError :: SandboxError -> Text
renderError err = case err of
  SandboxUnavailable bid msg -> "sandbox unavailable (" <> T.pack (show bid) <> "): " <> msg
  PolicyRejected msg -> "policy rejected: " <> msg
  RenderFailed msg -> "render failed: " <> msg
  LaunchFailed msg -> "launch failed: " <> msg
  ProbeFailed results -> "probe failed: " <> T.pack (show results)

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

runExec :: MVar (Map.Map Text Session) -> Scope -> BackendCapabilities -> Maybe Text -> Handle -> Text -> LaunchRequest -> LaunchPlan -> Maybe Text -> IO ()
runExec sessions scope caps experiment out cid request plan initialStdin = case lpArgv plan of
  [] -> writeFrame out (Error (Just cid) "backend" "empty argv")
  argv@(cmd : args) -> do
    record scope caps experiment AuditAllow
      ("exec " <> T.intercalate " " (lrArgv request))
#ifdef mingw32_HOST_OS
    if bcPlatform caps == Windows
      then runExecWindows scope caps experiment out cid request plan argv
      else runExecPosix sessions scope caps experiment out cid request initialStdin cmd args
#else
    runExecPosix sessions scope caps experiment out cid request initialStdin cmd args
#endif

-- | POSIX / macOS 路径：bwrap / sandbox-exec 已把隔离表达在 argv 里，
-- 这里只负责起进程并把 stdout/stderr 转成帧。
runExecPosix ::
  MVar (Map.Map Text Session) -> Scope -> BackendCapabilities -> Maybe Text -> Handle -> Text
  -> LaunchRequest -> Maybe Text -> Text -> [Text] -> IO ()
runExecPosix sessions scope caps experiment out cid request initialStdin cmd args = do
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

#ifdef mingw32_HOST_OS
-- ── Windows：AppContainer + Job + 目录授权 ────────────────────────────────

-- | Windows 启动路径。
--
-- 与 POSIX 的本质差别：隔离**不在 argv 里**，而是在进程创建那一刻由
-- @SECURITY_CAPABILITIES@ 属性与 capability SID 的 ACL 共同决定。所以这里必须
-- 自己做四件事：派生容器 SID、给可写目录授权、建 Job、先入 Job 再 resume。
--
-- 任何一步失败都写 @error@ 帧并停下——**没有不带隔离的回退路径**。
runExecWindows ::
  Scope -> BackendCapabilities -> Maybe Text -> Handle -> Text
  -> LaunchRequest -> LaunchPlan -> [Text] -> IO ()
runExecWindows scope caps experiment out cid request plan argv@(cmd : args) = do
  let containerName = "trha-sandbox-" <> T.unpack (unScopeId (scId scope))
  sidR <- W32AC.deriveContainerSid containerName
  case sidR of
    Left e -> failExec ("container SID: " <> T.pack (show e))
    Right sid -> do
      sidTextR <- W32AC.containerSidText sid
      case sidTextR of
        Left e -> do
          W32AC.freeContainerSid sid
          failExec ("sid text: " <> T.pack (show e))
        Right sidText -> do
          -- 1. 可写目录逐个授权；任一失败即中止
          grants <- mapM (\p -> W32Acl.grantWriteAccess p sidText) writeDirs
          case [ e | Left e <- grants ] of
            (err : _) -> do
              W32AC.freeContainerSid sid
              failExec ("acl: " <> T.pack (W32Acl.renderAclError err))
            [] -> do
              -- 2. Job 必须在 resume 之前建好，否则有逃逸窗口
              jobR <- W32Job.createJob W32Job.defaultJobLimits
              case jobR of
                Left e -> do
                  W32AC.freeContainerSid sid
                  failExec ("job: " <> T.pack (show e))
                Right job -> do
                  spR <- W32Proc.spawnAppContainer
                           sid (T.unpack cmd) (map T.unpack args)
                           (unAbsolutePath (lrCwd request))
                  case spR of
                    Left e -> do
                      W32Job.closeJob job
                      W32AC.freeContainerSid sid
                      failExec ("spawn: " <> T.pack (show e))
                    Right sp -> do
                      _ <- W32Job.assignToJob job (W32Proc.spProcess sp)
                      _ <- W32Proc.resumeThread sp
                      lock <- newMVar ()
                      outDone <- newEmptyMVar
                      errDone <- newEmptyMVar
                      _ <- forkIO $
                        drainPtr lock out (Stdout cid) Nothing
                          (W32Proc.spStdout sp)
                          `finally` putMVar outDone ()
                      _ <- forkIO $
                        drainPtr lock out (Stderr cid)
                          (Just (denySink scope caps experiment out cid))
                          (W32Proc.spStderr sp)
                          `finally` putMVar errDone ()
                      codeR <- waitWithTimeoutWin (lrTimeoutMs request) sp
                      takeMVar outDone
                      takeMVar errDone
                      W32Proc.closeSpawned sp
                      W32Job.closeJob job
                      W32AC.freeContainerSid sid
                      case codeR of
                        Left e -> failExec ("wait: " <> T.pack (show e))
                        Right code -> do
                          writeFrame out Exit
                            { exitId = cid
                            , exitCode = fromIntegral code
                            , exitSignal = Nothing
                            }
                          record scope caps experiment
                            (if code == 0 then AuditAllow else AuditError)
                            ("exit " <> T.pack (show code))
  where
    writeDirs =
      [ unAbsolutePath (msSource m)
      | m <- lpMounts plan
      , msMode m == MountReadWrite
      ]
    failExec msg = writeFrame out (Error (Just cid) "backend" msg)
runExecWindows _ _ _ out cid _ _ [] =
  writeFrame out (Error (Just cid) "backend" "empty argv")

-- | 带超时的等待。超时先 TerminateProcess 再返回 124（与 POSIX 分支一致）。
waitWithTimeoutWin ::
  Maybe Int -> W32Proc.SpawnedProcess -> IO (Either W32Proc.ProcessError Word32)
waitWithTimeoutWin (Just ms) sp = do
  waited <- timeout (fromIntegral ms * 1000) (W32Proc.waitForProcess sp)
  case waited of
    Just code -> pure code
    Nothing -> do
      W32Proc.terminateProcess sp
      pure (Right 124)
waitWithTimeoutWin Nothing sp = W32Proc.waitForProcess sp

-- | 把管道字节流切成行，逐行发帧。
--
-- 'W32Proc.readPipeChunks' 只给字节块，行边界可能跨块，所以用 IORef 保住半行；
-- 对端关闭后再把残留的最后一行（无换行结尾）补发出去。
drainPtr ::
  MVar () -> Handle -> (Text -> Frame) -> Maybe (Text -> IO ()) -> Ptr () -> IO ()
drainPtr lock out mkFrame onLine hPipe = do
  pendingRef <- newIORef BS.empty
  W32Proc.readPipeChunks hPipe $ \buf n -> do
    chunk <- BS.packCStringLen (castPtr buf, n)
    pending <- readIORef pendingRef
    let (complete, rest) = splitLines (pending <> chunk)
    writeIORef pendingRef rest
    mapM_ emitLine complete
  rest <- readIORef pendingRef
  if BS.null rest then pure () else emitLine rest
  where
    emitLine line = do
      let text = TE.decodeUtf8With TEE.lenientDecode (dropCR line)
      withMVar lock $ \_ -> writeFrame out (mkFrame text)
      maybe (pure ()) ($ text) onLine

-- | 按 LF 切行，返回 (完整行, 未完成的尾巴)。
splitLines :: BS.ByteString -> ([BS.ByteString], BS.ByteString)
splitLines = go []
  where
    go acc s = case BC.elemIndex '\n' s of
      Nothing -> (reverse acc, s)
      Just i ->
        let (line, rest) = BS.splitAt i s
        in go (line : acc) (BS.drop 1 rest)

-- | 去掉 CRLF 里的 CR。
dropCR :: BS.ByteString -> BS.ByteString
dropCR s
  | not (BS.null s) && BS.last s == 13 = BS.init s
  | otherwise = s
#endif

