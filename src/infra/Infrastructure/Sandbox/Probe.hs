{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Runtime probes (T1.5): positive/negative checks that the boundary is
-- actually enforced. Each probe runs through the normal renderer, so a probe
-- can never use a weaker path than a real tool call.
module Infrastructure.Sandbox.Probe
  ( Probe(..)
  , ProbeExpect(..)
  , ProbeResult(..)
  , defaultProbes
  , macProbes
  , windowsProbes
  , shellWrap
  , runProbes
  , runProbesWith
  , runProbe
  ) where

import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as T
import Infrastructure.Sandbox.Backend
  ( Backend, BackendCapabilities(..), Platform(..), planWith )
import Infrastructure.Sandbox.Error
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Policy
import Infrastructure.Sandbox.Scope
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
#ifdef mingw32_HOST_OS
import Data.IORef (newIORef, readIORef, writeIORef)
import Foreign (castPtr)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Infrastructure.Sandbox.Win32.Acl as W32Acl
import qualified Infrastructure.Sandbox.Win32.AppContainer as W32AC
import qualified Infrastructure.Sandbox.Win32.Process as W32Proc
#endif

data ProbeExpect = ExpectSuccess | ExpectFailure
  deriving (Eq, Show)

data Probe = Probe
  { prId      :: Text
  , prCommand :: Text
  , prExpect  :: ProbeExpect
  } deriving (Eq, Show)

-- | The P1 probe set. Paths are relative to the workspace; the write probe
-- targets a path outside it on purpose.
defaultProbes :: [Probe]
defaultProbes =
  [ Probe "write-workspace" "touch .trha-probe" ExpectSuccess
  , Probe "write-etc" "touch /etc/trha-probe" ExpectFailure
  , Probe "read-ssh" "cat \"$HOME/.ssh/id_rsa\"" ExpectFailure
  , Probe "network" "getent hosts example.com" ExpectFailure
  ]

runProbes :: Backend -> BackendCapabilities -> Scope -> IO [ProbeResult]
runProbes backend caps scope = runProbesWith backend caps scope defaultProbes

runProbesWith :: Backend -> BackendCapabilities -> Scope -> [Probe] -> IO [ProbeResult]
runProbesWith backend caps scope probes =
  mapM (runProbe backend caps scope) probes

-- | macOS variant: @getent@ does not exist there, so the network probe uses
-- curl.  The rest matches the Linux set.
macProbes :: [Probe]
macProbes =
  [ Probe "write-workspace" "touch .trha-probe" ExpectSuccess
  , Probe "write-etc" "touch /etc/trha-probe" ExpectFailure
  , Probe "read-ssh" "cat \"$HOME/.ssh/id_rsa\"" ExpectFailure
  , Probe "network" "curl -s --max-time 3 https://example.com" ExpectFailure
  ]

-- | Windows variant: @bash@ / @touch@ / @cat@ / @getent@ 都不存在，改用 cmd
-- 内建命令与 @ping@。与 POSIX 版一一对应：
--
--   * @write-workspace@：workspace 内可写（正例）
--   * @write-system@：系统目录不可写
--   * @read-ssh@：凭据文件读不到（容器里 @%USERPROFILE%@ 也未定义，同样失败）
--   * @network@：出站被阻断
--
-- 命令里**刻意不放空格**（@ok>file@ 而不是 @ok > file@）：'runProbePosix' 走
-- @readProcessWithExitCode@，它会给含空格的参数加引号，与 @cmd /c@ 自己的引号
-- 规则叠加后会把整条命令变成一个找不到的可执行文件（实测报「不是内部或外部
-- 命令」）。
--
-- **不**含「删 workspace 根」：那条在真实 workspace 上不可恢复，只在
-- @test/manual/AppContainerIsolation.hs@ 里针对一次性目录执行。
windowsProbes :: [Probe]
windowsProbes =
  [ Probe "write-workspace" "echo ok>.trha-probe" ExpectSuccess
  , Probe "write-system" "echo x>C:\\Windows\\trha-probe.txt" ExpectFailure
  , Probe "read-ssh" "type %USERPROFILE%\\.ssh\\id_rsa" ExpectFailure
  , Probe "network" "ping -n 1 -w 1000 example.com" ExpectFailure
  ]

-- | 把「一条 shell 命令」包装成 argv 前缀。
--
-- POSIX 走 @bash -lc@；Windows 走 @cmd /c@。这里必须做平台化，因为
-- 'readProcessWithExitCode' **不经过 shell**：直接传 @echo ok>file@ 只会把
-- @>@ 当成普通参数；而 @cmd /c@ 后面的参数会被 cmd 拼回一条命令行，重定向与
-- 内建命令因此才生效。
-- | 把「一条 shell 命令」包装成 argv 前缀。
--
-- POSIX 走 @bash -lc@；Windows 走 @cmd /s /c@。
--
-- Windows 侧的两个要点：
--
--   * 必须用**完整路径**：AppContainer 的环境块是空的，没有 @PATH@，裸 @cmd@
--     找不到可执行文件。
--   * 必须带 @/s@：'renderCommandLine' 会给含空格的参数加双引号，而
--     @cmd /c "echo x> f"@ 会把整串引号内容当成**可执行文件名**（实测报
--     「不是内部或外部命令」）。@/s@ 让 cmd 先剥掉最外层引号再按普通规则
--     解析，重定向与内建命令因此才生效。
shellWrap :: Platform -> Text -> [Text]
shellWrap Windows cmd = ["C:\\Windows\\System32\\cmd.exe", "/s", "/c", cmd]
shellWrap _ cmd = ["bash", "-lc", cmd]

runProbe :: Backend -> BackendCapabilities -> Scope -> Probe -> IO ProbeResult
runProbe backend caps scope probe =
  case planWith backend caps scope request of
    Left err -> pure (mkResult probe False (renderError err))
    Right plan -> case lpArgv plan of
      [] -> pure (mkResult probe False "empty argv")
      (cmd : args) ->
#ifdef mingw32_HOST_OS
        if bcPlatform caps == Windows
          then runProbeWindows scope probe cmd args
          else runProbePosix probe cmd args
#else
        runProbePosix probe cmd args
#endif
  where
    request = LaunchRequest
      { lrArgv = shellWrap (bcPlatform caps) (prCommand probe)
      , lrCwd = workspaceOf (scPolicy scope)
      , lrEnv = []
      , lrStdin = StdinClosed
      , lrTimeoutMs = Just 15000
      }

-- | POSIX / macOS：argv 里已经带了 bwrap / sandbox-exec 包装，直接执行即可。
runProbePosix :: Probe -> Text -> [Text] -> IO ProbeResult
runProbePosix probe cmd args = do
  attempted <- try (readProcessWithExitCode (T.unpack cmd) (map T.unpack args) "")
  pure $ case attempted of
    Left (e :: SomeException) -> mkResult probe False (T.pack (show e))
    Right (code, out, err) ->
      let ok = matches (prExpect probe) code
       in mkResult probe ok (clip (if ok then out else err))

mkResult :: Probe -> Bool -> Text -> ProbeResult
mkResult probe ok actual = ProbeResult
  { probeName = prId probe
  , probeOk = ok
  , probeExpected = expectText (prExpect probe)
  , probeActual = actual
  }

#ifdef mingw32_HOST_OS
-- | Windows：探针必须在 AppContainer 里跑。
--
-- 'renderWindows' 的 @lpArgv@ 不含隔离包装（隔离靠 CreateProcess 的
-- @SECURITY_CAPABILITIES@ 属性），所以不能像 POSIX 分支那样直接
-- @readProcessWithExitCode@——那样探针会在**沙箱外**执行，什么也测不出来。
--
-- 任一前置步骤失败都记成探针失败，不降级到沙箱外运行。
runProbeWindows :: Scope -> Probe -> Text -> [Text] -> IO ProbeResult
runProbeWindows scope probe cmd args = do
  let wrRoot = unAbsolutePath (workspaceOf (scPolicy scope))
      containerName = "trha-probe-" <> T.unpack (unScopeId (scId scope))
  sidR <- W32AC.deriveContainerSid containerName
  case sidR of
    Left e -> pure (mkResult probe False ("container SID: " <> T.pack (show e)))
    Right sid -> do
      sidTxtR <- W32AC.containerSidText sid
      case sidTxtR of
        Left e -> do
          W32AC.freeContainerSid sid
          pure (mkResult probe False ("sid text: " <> T.pack (show e)))
        Right sidText -> do
          grantR <- W32Acl.grantWriteAccess wrRoot sidText
          case grantR of
            Left err -> do
              W32AC.freeContainerSid sid
              pure (mkResult probe False ("acl: " <> T.pack (W32Acl.renderAclError err)))
            Right () -> do
              spR <- W32Proc.spawnAppContainer sid (T.unpack cmd) (map T.unpack args) wrRoot
              case spR of
                Left e -> do
                  W32AC.freeContainerSid sid
                  pure (mkResult probe False ("spawn: " <> T.pack (show e)))
                Right sp -> do
                  _ <- W32Proc.resumeThread sp
                  ref <- newIORef BS.empty
                  W32Proc.readPipeChunks (W32Proc.spStdout sp) $ \buf n -> do
                    chunk <- BS.packCStringLen (castPtr buf, n)
                    prev <- readIORef ref
                    writeIORef ref (prev <> chunk)
                  out <- readIORef ref
                  codeR <- W32Proc.waitForProcess sp
                  W32Proc.closeSpawned sp
                  W32AC.freeContainerSid sid
                  pure $ case codeR of
                    Left e -> mkResult probe False ("wait: " <> T.pack (show e))
                    Right code ->
                      let exitCode
                            | code == 0 = ExitSuccess
                            | otherwise = ExitFailure (fromIntegral code)
                          ok = matches (prExpect probe) exitCode
                       in mkResult probe ok (clip (BC.unpack out))
#endif

matches :: ProbeExpect -> ExitCode -> Bool
matches ExpectSuccess ExitSuccess = True
matches ExpectFailure code = code /= ExitSuccess
matches ExpectSuccess _ = False

expectText :: ProbeExpect -> Text
expectText ExpectSuccess = "success"
expectText ExpectFailure = "failure"

renderError :: SandboxError -> Text
renderError err = case err of
  SandboxUnavailable bid msg -> "sandbox unavailable (" <> T.pack (show bid) <> "): " <> msg
  PolicyRejected msg -> "policy rejected: " <> msg
  RenderFailed msg -> "render failed: " <> msg
  LaunchFailed msg -> "launch failed: " <> msg
  ProbeFailed results -> "probe failed: " <> T.pack (show results)

workspaceOf :: Policy -> AbsolutePath
workspaceOf policy = case policy of
  ReadOnly ro -> case roReadableRoots ro of
    (p : _) -> p
    [] -> AbsolutePath "/"
  WorkspaceWrite wr -> wrRoot wr
  DangerFullAccess -> AbsolutePath "/"

clip :: String -> Text
clip = T.take 500 . T.pack
