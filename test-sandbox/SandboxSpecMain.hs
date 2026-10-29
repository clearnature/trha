-- | Sandbox-only test suite.
--
-- `trha-test` depends on the local `sov-math` checkout (kernel math), which
-- macOS CI cannot resolve.  This suite pulls in only the sandbox specs so
-- the Linux integration cases run on Linux and turn into `pending` on
-- macOS (no bwrap), while the pure cases run everywhere.
module Main (main) where

import Test.Hspec
import AuditSpec (auditSpec)
import ConfigSpec (configSpec)
import ExperimentSpec (experimentSpec)
import SandboxLinuxSpec (sandboxLinuxSpec)
import SandboxMacSpec (sandboxMacSpec)
import SandboxRunnerSpec (sandboxRunnerSpec)
import SandboxSpec (sandboxSpec)

main :: IO ()
main = hspec $ do
  sandboxSpec
  sandboxLinuxSpec
  sandboxMacSpec
  sandboxRunnerSpec
  auditSpec
  experimentSpec
  configSpec
