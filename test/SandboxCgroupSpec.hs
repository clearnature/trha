{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | cgroup v2 pids limits (T2.3).
--
-- These run real cgroup operations. On a host without a delegated cgroup the
-- cases turn into @pending@ with the reason, mirroring SandboxLinuxSpec's
-- bwrap handling.
module SandboxCgroupSpec (sandboxCgroupSpec) where

import Control.Exception (SomeException, try)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Infrastructure.Sandbox.Cgroup
import System.Directory (doesDirectoryExist)
import System.Posix.Types (CPid(..))
import System.Process
  ( CreateProcess(..), StdStream(..), createProcess, getPid, proc, waitForProcess )
import Test.Hspec

sandboxCgroupSpec :: Spec
sandboxCgroupSpec = describe "cgroup v2 pids (T2.3)" $ do
  it "detects a delegated cgroup or explains why not" $ do
    support <- detectCgroup
    case support of
      Right s -> csBase s `shouldSatisfy` (not . null)
      Left reason -> T.length reason `shouldSatisfy` (> 0)

  it "creates a pids cgroup with the requested limit and removes it" $ do
    withSupport $ \s -> do
      created <- createPidsCgroup s "spec" 7
      case created of
        Left e -> expectationFailure (T.unpack e)
        Right cg -> do
          content <- readFile (cgroupPath cg ++ "/pids.max")
          content `shouldBe` "7\n"
          destroyPidsCgroup cg
          gone <- doesDirectoryExist (cgroupPath cg)
          gone `shouldBe` False

  it "refuses a base directory that does not exist" $ do
    let fake = CgroupSupport "/nonexistent/trha-cgroup" []
    created <- createPidsCgroup fake "spec" 5
    case created of
      Left _ -> pure ()
      Right cg -> do
        destroyPidsCgroup cg
        expectationFailure "created a cgroup under a nonexistent base"

  -- The point of cgroup pids: RLIMIT_NPROC counts the host uid, so it cannot
  -- express "this scope may have N tasks". Here 8 forks against pids.max=4
  -- must be counted as rejected.
  it "counts forks rejected by the pids limit" $ do
    withSupport $ \s -> do
      created <- createPidsCgroup s "spec-limit" 4
      case created of
        Left e -> expectationFailure (T.unpack e)
        Right cg -> do
          -- start the shell first, then move it in: forks happen after the move
          let cmd = "sleep 0.3; for i in 1 2 3 4 5 6 7 8; do sleep 0.4 & done; wait"
          (_, _, _, ph) <- createProcess (proc "sh" ["-c", cmd])
            { std_out = NoStream, std_err = NoStream }
          pid <- getPid ph
          case pid of
            Nothing -> pendingWith "no pid for the spawned shell"
            Just (CPid p) -> do
              _ <- addProcessTo cg (fromIntegral p)
              _ <- waitForProcess ph
              events <- try (readFile (cgroupPath cg ++ "/pids.events"))
                :: IO (Either SomeException String)
              case events of
                Left _ -> expectationFailure "cgroup disappeared before pids.events could be read"
                Right txt -> txt `shouldSatisfy` ("max " `isInfixOf`)
              destroyPidsCgroup cg

withSupport :: (CgroupSupport -> IO a) -> IO a
withSupport action = do
  support <- detectCgroup
  case support of
    Left reason -> pendingWith ("cgroup unavailable: " ++ T.unpack reason) >> fail "unreachable"
    Right s -> action s
