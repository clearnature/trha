{-# LANGUAGE OverloadedStrings #-}

-- | Windows backend：AppContainer + ACL + Job Object。
--
-- 隔离模型：
--
--   * 文件：capability SID 的 ACL（workspace 可写，其它路径拒绝；
--     @Everyone@ deny @FILE_DELETE_CHILD@ 防 rename/delete 逃逸）
--   * 资源：Job Object（@KILL_ON_JOB_CLOSE@ + 可选内存/进程数上限）
--   * 进程：@CreateProcess@ + @SECURITY_CAPABILITIES@（**全程免特权**）
--
-- 未覆盖：网络、PID 命名空间、系统调用过滤、凭据过滤——因此
-- 'bcEnforcement' 是 @Partial@ 而非 @Full@。
module Infrastructure.Sandbox.Backend.Windows
  ( backend
  , backendIdWindows
  , probeWindows
  ) where

import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Infrastructure.Sandbox.Backend
import Infrastructure.Sandbox.Error
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Policy
import Infrastructure.Sandbox.Scope
import Infrastructure.Sandbox.Win32.AppContainer (deriveContainerSid, freeContainerSid)

backendIdWindows :: BackendId
backendIdWindows = BackendId "windows-appcontainer"

backend :: Backend
backend = Backend
  { backendId = backendIdWindows
  , backendProbe = probeWindows
  , backendRender = renderWindows
  }

-- | 探测 AppContainer 是否可用。
--
-- 判据就是「能否从容器名派生出 SID」——这一步不需要任何特权，能过就说明
-- AppContainer 机制在本机可用。派生失败是硬失败（fail-closed）。
probeWindows :: IO (Either SandboxError BackendCapabilities)
probeWindows = do
  sidR <- deriveContainerSid "trha-sandbox-probe"
  case sidR of
    Left e -> pure (Left (SandboxUnavailable backendIdWindows
      ("AppContainer SID derivation failed: " <> T.pack (show e))))
    Right sid -> do
      freeContainerSid sid
      pure (Right capsPartial)

capsPartial :: BackendCapabilities
capsPartial = BackendCapabilities
  { bcBackend = backendIdWindows
  , bcPlatform = Windows
  , bcCapabilities = Set.fromList [CapFsRead, CapFsWrite, CapResource]
  , bcEnforcement = Partial (PartialReason
      (Set.fromList [CapNet, CapPid, CapSyscall, CapCred])
      "AppContainer confines filesystem writes and Job Object bounds resources; \
      \network / pid / syscall / credential are not confined")
  , bcNotes =
      [ "filesystem: capability SID ACL — allow write to workspace, deny FILE_DELETE_CHILD on Everyone"
      , "resources: Job Object — KILL_ON_JOB_CLOSE + optional memory/process caps"
      , "process: CreateProcess + SECURITY_CAPABILITIES (no SE_* privilege required)"
      , "not confined: network, pid namespace, syscall filtering, credential filtering"
      ]
  }

-- | 渲染 LaunchPlan。
--
-- Windows 的启动不需要 argv 包装（AppContainer 靠 CreateProcess 的
-- SECURITY_CAPABILITIES 属性），所以这里返回只携带后端标识、网络策略与资源
-- 限制的计划；真正的启动路径见
-- 'Infrastructure.Sandbox.Win32.Process.spawnAppContainer'，由 Runner 在
-- Windows 分支调用。
renderWindows :: Scope -> LaunchRequest -> Either SandboxError LaunchPlan
renderWindows scope req = do
  (mounts, network, limits) <- policySurface (scPolicy scope)
  pure LaunchPlan
    { lpBackend = backendIdWindows
    , lpArgv = lrArgv req
    , lpEnforcement = Partial (PartialReason
        (Set.fromList [CapNet, CapPid, CapSyscall, CapCred])
        "AppContainer: filesystem + resources only")
    , lpMounts = mounts
    , lpNetwork = network
    , lpLimits = limits
    }

-- | 把策略翻译成「需要授权给容器 SID 的目录清单」。
--
-- @MountReadWrite@ 的目录由 Runner 调 'grantWriteAccess' 授权（写 + 删 + 删子项，
-- 同时附上 Everyone 的 deny FILE_DELETE_CHILD）；@MountReadOnly@ 的目录无需授权。
policySurface :: Policy -> Either SandboxError ([MountSpec], NetworkPolicy, ResourceLimits)
policySurface policy = case policy of
  DangerFullAccess ->
    Left (PolicyRejected "danger-full-access cannot be rendered; construct a concrete policy")
  ReadOnly ro -> Right
    ( [ MountSpec (AbsolutePath p) (AbsolutePath p) MountReadOnly
      | p <- map unAbsolutePath (roReadableRoots ro) ]
    , roNetwork ro
    , defaultResourceLimits )
  WorkspaceWrite wr -> Right
    ( [ MountSpec (AbsolutePath root) (AbsolutePath root) MountReadWrite
      | root <- [ unAbsolutePath (wrRoot wr)
                , unAbsolutePath (unExclusivePath (wrScratch wr)) ] ]
      <> [ MountSpec (AbsolutePath p) (AbsolutePath p) MountReadOnly
         | p <- map unAbsolutePath (wrReadOnly wr) ]
    , wrNetwork wr
    , wrLimits wr )
