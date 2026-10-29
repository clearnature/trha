{-# LANGUAGE OverloadedStrings #-}

-- | Real-bwrap integration probes (T1.5). Skipped when bwrap/userns is
-- unavailable, so the suite stays usable on restricted hosts.
module SandboxLinuxSpec (sandboxLinuxSpec) where

import Control.Exception (SomeException, finally, try)
import Data.Text (Text)
import qualified Data.Text as T
import Infrastructure.Sandbox
import qualified Infrastructure.Sandbox.Backend.Linux as Linux
import Infrastructure.Sandbox.Experiment
import Infrastructure.Sandbox.Plan (LaunchRequest(..), LaunchPlan(..), StdinMode(..))
import Infrastructure.Sandbox.Probe
import System.Directory
  ( createDirectoryIfMissing, getHomeDirectory, removeDirectoryRecursive )
import System.Environment (lookupEnv, setEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Process (readProcessWithExitCode)
import Test.Hspec

-- | Nested sandboxes (this suite running inside another bwrap) cannot create a
-- user namespace, so bwrap still exists but probes partial.  Turn that into a
-- pending instead of a false failure — the boundary itself is fine, this host
-- just will not let us re-enter it.
withFullBwrap :: BackendCapabilities -> IO () -> IO ()
withFullBwrap c action
  | bcEnforcement c == Full = action
  | otherwise = pendingWith
      ("bwrap cannot create a namespace here: " ++ show (bcEnforcement c))

sandboxLinuxSpec :: Spec
sandboxLinuxSpec = describe "Linux sandbox integration (T1.5)" $ do
  it "enforces workspace-write and denies writes outside it" $ do
    caps <- Linux.probeLinux
    case caps of
      Left (SandboxUnavailable _ msg) ->
        pendingWith ("bwrap unavailable: " ++ show msg)
      Left e -> expectationFailure (show e)
      Right c -> withFullBwrap c $ do
        home <- getHomeDirectory
        let ws = home </> ".trha-sandbox-probe-test"
        createDirectoryIfMissing True ws
        results <- runProbes Linux.backend c (probeScope ws)
        cleaned <- try (removeDirectoryRecursive ws) :: IO (Either SomeException ())
        case cleaned of
          Left e -> expectationFailure ("cleanup failed: " ++ show e)
          Right () -> pure ()
        map probeName results
          `shouldBe` ["write-workspace", "write-etc", "read-ssh", "network"]
        map probeOk results `shouldBe` [True, True, True, True]

  it "can run the host toolchain inside the sandbox (T1.9)" $ do
    caps <- Linux.probeLinux
    case caps of
      Left (SandboxUnavailable _ msg) ->
        pendingWith ("bwrap unavailable: " ++ show msg)
      Left e -> expectationFailure (show e)
      Right c -> withFullBwrap c $ do
        home <- getHomeDirectory
        let ws = home </> ".trha-sandbox-toolchain"
        createDirectoryIfMissing True ws
        hostPath <- maybe "" id <$> lookupEnv "PATH"
        let request = LaunchRequest
              { lrArgv =
                  [ "bash", "-c"
                  , "command -v ghc >/dev/null && ghc --version && command -v node >/dev/null && node --version"
                  ]
              , lrCwd = AbsolutePath ws
              , lrEnv = [("PATH", T.pack hostPath)]
              , lrStdin = StdinClosed
              , lrTimeoutMs = Just 60000
              , lrDenyReads = []
              }
        case planWith Linux.backend c (probeScope ws) request of
          Left e -> expectationFailure (show e)
          Right plan -> case lpArgv plan of
            [] -> expectationFailure "empty argv"
            (cmd : args) -> do
              (code, out, err) <- readProcessWithExitCode (T.unpack cmd) (map T.unpack args) ""
              _ <- try (removeDirectoryRecursive ws) :: IO (Either SomeException ())
              code `shouldBe` ExitSuccess
              out `shouldSatisfy` T.isInfixOf "Glorious Glasgow Haskell Compilation System" . T.pack
              err `seq` pure ()

  it "applies the memory limit inside the sandbox (T2.3)" $ do
    caps <- Linux.probeLinux
    case caps of
      Left (SandboxUnavailable _ msg) ->
        pendingWith ("bwrap unavailable: " ++ show msg)
      Left e -> expectationFailure (show e)
      Right c -> withFullBwrap c $ do
        home <- getHomeDirectory
        let ws = home </> ".trha-sandbox-limits"
        createDirectoryIfMissing True ws
        let scope = (probeScope ws)
              { scPolicy = WorkspaceWrite WritableRoot
                  { wrRoot = AbsolutePath ws
                  , wrScratch = ExclusivePath (AbsolutePath ws)
                  , wrReadOnly = []
                  , wrNetwork = NetworkOff
                  , wrLimits = defaultResourceLimits { rlMemoryMiB = 256 }
                  } }
            request = LaunchRequest
              { lrArgv = ["bash", "-c", "ulimit -v"]
              , lrCwd = AbsolutePath ws
              , lrEnv = []
              , lrStdin = StdinClosed
              , lrTimeoutMs = Just 30000
              , lrDenyReads = []
              }
        case planWith Linux.backend c scope request of
          Left e -> expectationFailure (show e)
          Right plan -> case lpArgv plan of
            [] -> expectationFailure "empty argv"
            (cmd : args) -> do
              (code, out, _) <- readProcessWithExitCode
                (T.unpack cmd) (map T.unpack args) ""
              _ <- try (removeDirectoryRecursive ws) :: IO (Either SomeException ())
              code `shouldBe` ExitSuccess
              T.strip (T.pack out) `shouldBe` "262144"

  it "isolates pid and net namespaces (T2.4)" $ do
    caps <- Linux.probeLinux
    case caps of
      Left (SandboxUnavailable _ msg) ->
        pendingWith ("bwrap unavailable: " ++ show msg)
      Left e -> expectationFailure (show e)
      Right c -> withFullBwrap c $ do
        home <- getHomeDirectory
        let ws = home </> ".trha-sandbox-ns"
        createDirectoryIfMissing True ws
        let script = "ls /proc | grep -cE '^[0-9]+$'; cat /proc/net/tcp 2>/dev/null | wc -l"
            request = LaunchRequest
              { lrArgv = ["bash", "-c", script]
              , lrCwd = AbsolutePath ws
              , lrEnv = []
              , lrStdin = StdinClosed
              , lrTimeoutMs = Just 30000
              , lrDenyReads = []
              }
        case planWith Linux.backend c (probeScope ws) request of
          Left e -> expectationFailure (show e)
          Right plan -> case lpArgv plan of
            [] -> expectationFailure "empty argv"
            (cmd : args) -> do
              (code, out, _) <- readProcessWithExitCode
                (T.unpack cmd) (map T.unpack args) ""
              _ <- try (removeDirectoryRecursive ws) :: IO (Either SomeException ())
              code `shouldBe` ExitSuccess
              case lines out of
                (pids : tcp : _) -> do
                  -- Only bwrap + the command's own processes exist in the
                  -- private pid namespace (a host would show hundreds).
                  readInt pids `shouldSatisfy` maybe False (<= 8)
                  readInt tcp `shouldSatisfy` maybe False (<= 1)
                _ -> expectationFailure ("unexpected output: " ++ show out)

  it "keeps sibling experiment scopes isolated (T2.5)" $ do
    caps <- Linux.probeLinux
    case caps of
      Left (SandboxUnavailable _ msg) ->
        pendingWith ("bwrap unavailable: " ++ show msg)
      Left e -> expectationFailure (show e)
      Right c -> withFullBwrap c $ do
        home <- getHomeDirectory
        let root = home </> ".trha-sandbox-experiment"
            variantA = Variant (VariantId "a") NetworkOff
            variantB = Variant (VariantId "b") NetworkOff
            batch = ExperimentBatch
              { ebId = BatchId "e2e"
              , ebRoot = AbsolutePath root
              , ebBaseline = AbsolutePath (root </> "baseline")
              , ebVariants = [variantA, variantB]
              , ebSeeds = [Seed 1]
              , ebLimits = defaultResourceLimits
              , ebConcurrency = 1
              }
            workA = workDir batch variantA (Seed 1)
            workB = workDir batch variantB (Seed 1)
        createDirectoryIfMissing True (root </> "baseline")
        createDirectoryIfMissing True workA
        createDirectoryIfMissing True workB
        case variantScope (probeScope root) batch variantA (Seed 1) of
          Left e -> expectationFailure (show e)
          Right scopeA -> do
            let script = T.concat
                  [ "touch ", T.pack (workA </> "ok.txt"), " && (touch "
                  , T.pack (workB </> "leak.txt"), " && exit 7 || exit 0)" ]
                request = LaunchRequest
                  { lrArgv = ["bash", "-c", script]
                  , lrCwd = AbsolutePath workA
                  , lrEnv = []
                  , lrStdin = StdinClosed
                  , lrTimeoutMs = Just 30000
                  , lrDenyReads = []
                  }
            case planWith Linux.backend c scopeA request of
              Left e -> expectationFailure (show e)
              Right plan -> case lpArgv plan of
                [] -> expectationFailure "empty argv"
                (cmd : args) -> do
                  (code, _, _) <- readProcessWithExitCode
                    (T.unpack cmd) (map T.unpack args) ""
                  _ <- try (removeDirectoryRecursive root) :: IO (Either SomeException ())
                  code `shouldBe` ExitSuccess

  -- T5.3: bwrap present but unable to unshare must degrade to Partial with the
  -- reason visible — never fail open, never claim Full.
  it "degrades to Partial when bwrap cannot unshare (T5.3)" $ do
    home <- getHomeDirectory
    let dir = home </> ".trha-fake-bwrap"
        fake = dir </> "bwrap"
    createDirectoryIfMissing True dir
    writeFile fake "#!/bin/sh\nexit 1\n"
    setFileMode fake 0o755
    oldPath <- lookupEnv "PATH"
    let newPath = dir ++ ":" ++ maybe "" id oldPath
    caps <- (setEnv "PATH" newPath >> Linux.probeLinux)
      `finally` maybe (pure ()) (setEnv "PATH") oldPath
    case caps of
      Left e -> expectationFailure ("probe should degrade, not fail: " ++ show e)
      Right c -> withFullBwrap c $ do
        bcEnforcement c `shouldSatisfy` isPartialEnforcement
        bcNotes c `shouldSatisfy` any ("bwrap probe failed" `T.isInfixOf`)

readInt :: String -> Maybe Int
readInt raw = case reads raw :: [(Int, String)] of
  [(n, "")] -> Just n
  _ -> Nothing

probeScope :: FilePath -> Scope
probeScope ws = scopeRoot (ScopeId "probe") policy (ExclusivePath (AbsolutePath ws))
  where
    policy = WorkspaceWrite WritableRoot
      { wrRoot = AbsolutePath ws
      , wrScratch = ExclusivePath (AbsolutePath ws)
      , wrReadOnly = []
      , wrNetwork = NetworkOff
      , wrLimits = defaultResourceLimits
      }

isPartialEnforcement :: Enforcement -> Bool
isPartialEnforcement (Partial _) = True
isPartialEnforcement _ = False
