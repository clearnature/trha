{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Run-state files and the @trha stop@ / @trha status@ implementation.
--
-- Every service writes @~/.trha/run/<service>.pid@ (0600 in a 0700 directory)
-- while it runs and removes it on exit.  Stopping is deliberately conservative:
--
--   * only the pid recorded in the file is signalled — never a name match
--     (@pkill@) and never a port sweep, both of which can hit an unrelated
--     process;
--   * the pid is checked against @\/proc\/\<pid\>\/cmdline@ first, so a recycled
--     pid is refused rather than killed;
--   * SIGTERM only.  A process that does not exit within five seconds is
--     reported as a timeout; @--force@ is required to escalate to SIGKILL.
--
-- The same module backs @trha stop@ for both services; the TUI's @\/stop@
-- calls 'stopAll' directly.
module Core.RunState
  ( -- * Services
    Service(..)
  , serviceName
  , parseService
    -- * Run files
  , runDir
  , pidFile
  , PidOutcome(..)
  , writePid
  , removePid
  , readPid
    -- * Stopping
  , StopResult(..)
  , stopResultText
  , stopService
  , stopAll
    -- * Status
  , ServiceStatus(..)
  , serviceStatuses
  , statusText
    -- * Runtime registry (single source for ports/tokens)
  , RuntimeEntry(..)
  , runtimeFile
  , readRuntimeEntry
  , parseRuntimeEntry
  , writeRuntimeSection
  , writeRuntimeNow
  , removeRuntimeSection
    -- * Pure helpers (tested)
  , looksLikeOurProcess
  , zombieStat
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Char (isDigit, toLower)
import Data.List (isInfixOf)
import Data.Aeson (Value(..), decode, encode, object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Aeson.Types (parseMaybe, (.:))
import System.Directory
    ( createDirectoryIfMissing, doesFileExist, getHomeDirectory, removeFile, renameFile )
import System.FilePath (takeDirectory, (</>))
import Control.Concurrent (threadDelay)

#ifndef mingw32_HOST_OS
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (nullSignal, sigKILL, sigTERM, signalProcess)
#endif

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------

data Service = Kernel | Scheduler
  deriving (Show, Eq, Enum, Bounded)

serviceName :: Service -> String
serviceName Kernel    = "kernel"
serviceName Scheduler = "scheduler"

parseService :: String -> Maybe Service
parseService raw = case map toLower raw of
  "kernel"    -> Just Kernel
  "scheduler" -> Just Scheduler
  _           -> Nothing

--------------------------------------------------------------------------------
-- Run files
--------------------------------------------------------------------------------

-- | @~/.trha/run@ (0700).
runDir :: IO FilePath
runDir = do
  home <- getHomeDirectory
  let dir = home </> ".trha" </> "run"
  createDirectoryIfMissing True dir
  setOwnerOnlyDir dir
  pure dir

setOwnerOnlyDir :: FilePath -> IO ()
#ifndef mingw32_HOST_OS
setOwnerOnlyDir p = do
  _ <- try (setFileMode p 0o700) :: IO (Either IOError ())
  pure ()
#else
setOwnerOnlyDir _ = pure ()
#endif

pidFile :: Service -> IO FilePath
pidFile svc = (</> serviceName svc ++ ".pid") <$> runDir

-- | What happened when a service tried to claim its pid file.
data PidOutcome = PidWritten | PidOwnedBy Int
  deriving (Show, Eq)

-- | Record the current process as the service.
--
-- A pid file that names a *live* process of the same kind is not overwritten:
-- starting a second kernel/scheduler would either lose track of the first one
-- or silently shadow it.  A dead pid, or one whose cmdline does not match, is
-- stale and may be replaced.
writePid :: Service -> IO PidOutcome
#ifndef mingw32_HOST_OS
writePid svc = do
  path <- pidFile svc
  me <- currentPid
  existing <- readPid svc
  keep <- case existing of
    Just pid | pid /= me -> do
      alive <- pidAlive pid
      ours <- if alive then pidMatches svc pid else pure False
      pure (alive && ours)
    _ -> pure False
  if keep
    then pure (PidOwnedBy (fromMaybe' me existing))
    else do
      BS.writeFile path (BC.pack (show me))
      setOwnerOnlyFile path
      pure PidWritten
  where
    fromMaybe' d = maybe d id
#else
writePid _ = pure PidWritten
#endif

-- | Remove the pid file, but only when it still names this process.
removePid :: Service -> IO ()
removePid svc = do
  path <- pidFile svc
  pid <- currentPid
  stored <- readPid svc
  case stored of
    Just p | p == pid -> ignoreIO (removeFile path)
    _                 -> pure ()

readPid :: Service -> IO (Maybe Int)
readPid svc = do
  path <- pidFile svc
  exists <- doesFileExist path
  if not exists then pure Nothing else do
    raw <- try (BS.readFile path) :: IO (Either IOException ByteString)
    pure $ case raw of
      Left _ -> Nothing
      Right bs ->
        let digits = BC.takeWhile isDigit (BC.dropWhile (== ' ') (BC.strip bs))
        in if BC.null digits then Nothing else Just (read (BC.unpack digits))

currentPid :: IO Int
#ifndef mingw32_HOST_OS
currentPid = fromIntegral <$> getProcessID
#else
currentPid = pure 0
#endif

setOwnerOnlyFile :: FilePath -> IO ()
#ifndef mingw32_HOST_OS
setOwnerOnlyFile p = do
  _ <- try (setFileMode p (ownerReadMode `unionFileModes` ownerWriteMode)) :: IO (Either IOError ())
  pure ()
#else
setOwnerOnlyFile _ = pure ()
#endif

ignoreIO :: IO () -> IO ()
ignoreIO act = do
  _ <- try act :: IO (Either IOException ())
  pure ()

--------------------------------------------------------------------------------
-- Stopping
--------------------------------------------------------------------------------

data StopResult
  = NotRunning
  | Stopped Int
  | Forced Int
  | Timeout Int
  | Refused Int String
  | StopUnsupported
  deriving (Show, Eq)

stopResultText :: Service -> StopResult -> String
stopResultText svc r = case r of
  NotRunning      -> serviceName svc ++ ": not running (no pid file)"
  Stopped pid     -> serviceName svc ++ ": stopped (pid " ++ show pid ++ ")"
  Forced pid      -> serviceName svc ++ ": killed after timeout (pid " ++ show pid ++ ")"
  Timeout pid     -> serviceName svc ++ ": pid " ++ show pid
                       ++ " did not exit within 5s (use --force to SIGKILL)"
  Refused pid why -> serviceName svc ++ ": refused to stop pid " ++ show pid ++ " — " ++ why
  StopUnsupported -> serviceName svc ++ ": stopping is not supported on this platform"

-- | Stop one service.  'force' escalates to SIGKILL after the timeout.
stopService :: Service -> Bool -> IO StopResult
#ifndef mingw32_HOST_OS
stopService svc force = do
  mp <- readPid svc
  case mp of
    Nothing -> pure NotRunning
    Just pid -> do
      alive <- pidAlive pid
      if not alive
        then do ignoreIO (removePidFile svc); pure NotRunning
        else do
          ours <- pidMatches svc pid
          if not ours
            then pure (Refused pid "the pid file points at a different process")
            else do
              ignoreIO (signalProcess sigTERM (fromIntegral pid))
              gone <- waitGone pid 5000
              if gone
                then do ignoreIO (removePidFile svc); pure (Stopped pid)
                else if force
                  then do
                    ignoreIO (signalProcess sigKILL (fromIntegral pid))
                    _ <- waitGone pid 2000
                    ignoreIO (removePidFile svc)
                    pure (Forced pid)
                  else pure (Timeout pid)
#else
stopService _ _ = pure StopUnsupported
#endif

removePidFile :: Service -> IO ()
removePidFile svc = pidFile svc >>= removeFile

pidAlive :: Int -> IO Bool
#ifndef mingw32_HOST_OS
pidAlive pid =
  if pid <= 0 then pure False else do
    r <- try (signalProcess nullSignal (fromIntegral pid)) :: IO (Either IOException ())
    case r of
      Left _ -> pure False
      Right _ -> do
        -- A zombie still accepts signal 0.  Without this check a service whose
        -- process already exited reads as alive forever, and 'stopService'
        -- burns its whole 5 s budget — twice, serially — before Ctrl+Alt+Q
        -- returns.  That regression appeared when the CLI started spawning the
        -- kernel itself (Core.Bootstrap drops the ProcessHandle, so nothing
        -- ever reaps it).
        st <- try (readFile ("/proc/" ++ show pid ++ "/stat")) :: IO (Either IOException String)
        pure $ case st of
          Right s -> not (zombieStat s)
          Left _ -> True   -- no procfs to consult: trust the signal probe
#else
pidAlive _ = pure False
#endif

-- | Does this @\/proc\/<pid>\/stat@ line describe a zombie?
--
-- The format is @pid (comm) STATE ...@, and @comm@ may itself contain spaces
-- and parentheses (e.g. @node (dist/cli.js)@), so the state is the first field
-- after the *last* @)@ — not after the first one.
zombieStat :: String -> Bool
zombieStat s = case drop (lastParen + 1) s of
  (' ' : st : _) -> st == 'Z'
  _ -> False
  where
    lastParen = case [ i | (i, c) <- zip [0 :: Int ..] s, c == ')' ] of
      [] -> -1
      is -> last is

waitGone :: Int -> Int -> IO Bool
waitGone pid totalMs = go (max 1 (totalMs `div` 100))
  where
    go 0 = pidAlive pid >>= \a -> pure (not a)
    go n = do
      alive <- pidAlive pid
      if not alive then pure True else do
        threadDelay 100000
        go (n - 1)

-- | Refuse a recycled pid: the recorded process must still look like ours.
pidMatches :: Service -> Int -> IO Bool
pidMatches svc pid
#ifndef mingw32_HOST_OS
  = do
      r <- try (BS.readFile ("/proc/" ++ show pid ++ "/cmdline"))
             :: IO (Either IOException ByteString)
      pure $ case r of
        Left _  -> True          -- no /proc (non-Linux): trust the pid file
        Right cl -> looksLikeOurProcess svc cl
#else
  = pure True
#endif

-- | Does this @\/proc\/\<pid\>\/cmdline@ (NUL-separated) belong to the service?
--
-- Kernel: the @trha@ binary running @serve@.  Scheduler: a Node process whose
-- script is @cli.js@ (packaged or @dist/cli.js@).
looksLikeOurProcess :: Service -> ByteString -> Bool
looksLikeOurProcess svc raw =
  let text = BC.unpack (BC.map nulToSpace raw)
  in case svc of
       Kernel    -> "trha" `isInfixOf` text
                      && ("serve" `isInfixOf` text || "kernel-stub" `isInfixOf` text)
       Scheduler -> "cli.js" `isInfixOf` text
  where
    nulToSpace c = if c == '\0' then ' ' else c

stopAll :: Bool -> IO [(Service, StopResult)]
stopAll force = forM [minBound .. maxBound] $ \svc -> do
  r <- stopService svc force
  pure (svc, r)

--------------------------------------------------------------------------------
-- Status
--------------------------------------------------------------------------------

data ServiceStatus = ServiceStatus
  { ssService :: Service
  , ssPid     :: Maybe Int
  , ssAlive   :: Bool
  } deriving (Show, Eq)

serviceStatuses :: IO [ServiceStatus]
serviceStatuses = forM [minBound .. maxBound] $ \svc -> do
  mp <- readPid svc
  alive <- case mp of
    Nothing  -> pure False
    Just pid -> pidAlive pid
  pure (ServiceStatus svc mp alive)

statusText :: [ServiceStatus] -> String
statusText rows = unlines
  [ serviceName (ssService r)
      ++ ": " ++ maybe "(no pid file)" (\p -> "pid " ++ show p) (ssPid r)
      ++ (if ssAlive r then " (running)" else " (not running)")
  | r <- rows ]

--------------------------------------------------------------------------------
-- Runtime registry: ~/.trha/runtime.json
--
-- One file both services write their own section into, so a shell can discover
-- the live port and token instead of guessing from settings.  Sections are
-- replaced atomically (read-modify-write + rename) and only the owner may
-- remove its own pid.
--------------------------------------------------------------------------------

data RuntimeEntry = RuntimeEntry
  { reHost      :: String
  , rePort      :: Int
  , rePid       :: Int
  , reToken     :: String
  , reStartedAt :: Double
  } deriving (Show, Eq)

runtimeFile :: IO FilePath
runtimeFile = do
  home <- getHomeDirectory
  pure (home </> ".trha" </> "runtime.json")

runtimeKey :: Service -> Key.Key
runtimeKey svc = Key.fromText (T.pack (serviceName svc))

readRuntimeRoot :: IO Value
readRuntimeRoot = do
  p <- runtimeFile
  exists <- doesFileExist p
  if not exists
    then pure (Object KM.empty)
    else do
      raw <- try (BL.readFile p) :: IO (Either IOException BL.ByteString)
      pure $ case raw of
        Left _  -> Object KM.empty
        Right b -> maybe (Object KM.empty) id (decode b)

readRuntimeEntry :: Service -> IO (Maybe RuntimeEntry)
readRuntimeEntry svc = parseRuntimeEntry svc <$> readRuntimeRoot

-- | Pure half: pick one section out of the registry document.
parseRuntimeEntry :: Service -> Value -> Maybe RuntimeEntry
parseRuntimeEntry svc (Object o) = case KM.lookup (runtimeKey svc) o of
  Just (Object e) -> RuntimeEntry
    <$> parseMaybe (.: "host") e
    <*> parseMaybe (.: "port") e
    <*> parseMaybe (.: "pid") e
    <*> parseMaybe (.: "token") e
    <*> pure (maybe 0 id (parseMaybe (.: "startedAt") e))
  _ -> Nothing
parseRuntimeEntry _ _ = Nothing

writeRuntimeSection :: Service -> RuntimeEntry -> IO ()
writeRuntimeSection svc e = do
  p <- runtimeFile
  cur <- readRuntimeRoot
  let entry = object
        [ "host" .= reHost e, "port" .= rePort e, "pid" .= rePid e
        , "token" .= reToken e, "startedAt" .= reStartedAt e ]
      merged = case cur of
        Object o -> Object (KM.insert (runtimeKey svc) entry o)
        _        -> object [runtimeKey svc .= entry]
      tmp = p ++ ".tmp"
  createDirectoryIfMissing True (takeDirectory p)
  BL.writeFile tmp (encode merged)
  setOwnerOnlyFile tmp
  renameFile tmp p

removeRuntimeSection :: Service -> IO ()
removeRuntimeSection svc = do
  p <- runtimeFile
  cur <- readRuntimeRoot
  me <- currentPid
  case cur of
    Object o -> case KM.lookup (runtimeKey svc) o of
      Just (Object e)
        | (parseMaybe (.: "pid") e :: Maybe Int) == Just me -> do
            let tmp = p ++ ".tmp"
            BL.writeFile tmp (encode (Object (KM.delete (runtimeKey svc) o)))
            setOwnerOnlyFile tmp
            renameFile tmp p
      _ -> pure ()
    _ -> pure ()

-- | Record this process as the service, then stamp the start time.
writeRuntimeNow :: Service -> String -> Int -> String -> IO ()
writeRuntimeNow svc host port token = do
  now <- realToFrac <$> getPOSIXTime
  pid <- currentPid
  writeRuntimeSection svc (RuntimeEntry host port pid token now)

