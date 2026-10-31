{-# LANGUAGE CPP #-}

-- | Sandbox-only test suite.
--
-- `trha-test` depends on the local `sov-math` checkout (kernel math), which
-- macOS CI cannot resolve.  This suite pulls in only the sandbox specs so
-- the Linux integration cases run on Linux and turn into `pending` on
-- macOS (no bwrap), while the pure cases run everywhere.
--
-- Windows：Linux/macOS/BSD 专用 spec 整个不参与构建（它们 import
-- System.Posix.* 或 Linux cgroup API），见 trha.cabal 的 other-modules 条件。
-- Windows 上保留的只有纯函数/配置类用例。
module Main (main) where

import Test.Hspec

import AuditSpec (auditSpec)
import ConfigSpec (configSpec, sandboxGuestSpec)
import ExperimentSpec (experimentSpec)
import SandboxSpec (sandboxSpec)

#ifndef mingw32_HOST_OS
import SandboxBsdSpec (sandboxBsdSpec)
import SandboxCgroupSpec (sandboxCgroupSpec)
import SandboxLandlockSpec (sandboxLandlockSpec)
import SandboxLinuxSpec (sandboxLinuxSpec)
import SandboxMacSpec (sandboxMacSpec)
import SandboxRunnerSpec (sandboxRunnerSpec)
#endif

main :: IO ()
main = hspec $ do
  sandboxSpec
#ifndef mingw32_HOST_OS
  sandboxLinuxSpec
  sandboxMacSpec
  sandboxRunnerSpec
  sandboxCgroupSpec
  sandboxBsdSpec
  sandboxLandlockSpec
#endif
  auditSpec
  experimentSpec
  configSpec
  sandboxGuestSpec
