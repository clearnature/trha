{-# LANGUAGE OverloadedStrings #-}

-- | T1.7 audit log tests: append, read, limit.
module AuditSpec (auditSpec) where

import Data.Text (Text)
import qualified Data.Text as T
import Infrastructure.Sandbox.Audit
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import Test.Hspec

auditSpec :: Spec
auditSpec = describe "sandbox audit (T1.7)" $ do
  it "appends JSON lines and reads them back" $ do
    path <- tempFile "append"
    appendAuditAt path (event AuditAllow "exec echo hi")
    appendAuditAt path (event AuditDeny "write /etc/passwd")
    events <- readAuditAt path 10
    map aeKind events `shouldBe` [AuditAllow, AuditDeny]
    map aeTarget events `shouldBe` ["exec echo hi", "write /etc/passwd"]
    map aeScope events `shouldBe` ["scope-1", "scope-1"]
    aeTs (head events) `shouldSatisfy` (not . T.null)
    cleanup path

  it "returns only the last N events" $ do
    path <- tempFile "limit"
    mapM_ (\n -> appendAuditAt path (event AuditAllow (T.pack ("exec " <> show n)))) [1 .. 5 :: Int]
    events <- readAuditAt path 2
    map aeTarget events `shouldBe` ["exec 4", "exec 5"]
    cleanup path

  it "returns [] when the file does not exist" $ do
    path <- tempFile "missing"
    readAuditAt path 10 `shouldReturn` []

event :: AuditKind -> Text -> AuditEvent
event kind target = AuditEvent
  { aeTs = ""
  , aeScope = "scope-1"
  , aeKind = kind
  , aeTarget = target
  , aeBackend = "linux-bwrap"
  , aeEnforcement = "Full"
  , aeExperiment = Nothing
  }

tempFile :: String -> IO FilePath
tempFile tag = do
  tmp <- getTemporaryDirectory
  let path = tmp </> ("trha-audit-" <> tag <> ".jsonl")
  cleanup path
  pure path

cleanup :: FilePath -> IO ()
cleanup path = do
  exists <- doesFileExist path
  if exists then removeFile path else pure ()
