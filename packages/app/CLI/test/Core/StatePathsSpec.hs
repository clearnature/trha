{-# LANGUAGE OverloadedStrings #-}

module Core.StatePathsSpec (spec) where

import Control.Exception (bracket)
import System.Directory
    ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist
    , getTemporaryDirectory, removePathForcibly )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import Test.Hspec

import Core.StatePaths (migrateLegacy, stateReadPath, stateWritePath)

spec :: Spec
spec = describe "state paths" $ do
  it "writes under ~/.trha/state and creates the directory" $
    withTempHome $ \home -> do
      path <- stateWritePath "frecency.json"
      path `shouldBe` home </> ".trha" </> "state" </> "frecency.json"
      doesDirectoryExist (home </> ".trha" </> "state") `shouldReturn` True

  it "reads the legacy file while the new one is missing" $
    withTempHome $ \home -> do
      let legacy = home </> ".trha" </> "frecency.json"
      createDirectoryIfMissing True (home </> ".trha")
      writeFile legacy "{}"
      stateReadPath "frecency.json" `shouldReturn` legacy

  it "prefers the new file once it exists" $
    withTempHome $ \home -> do
      let legacy = home </> ".trha" </> "frecency.json"
      createDirectoryIfMissing True (home </> ".trha")
      writeFile legacy "{}"
      new <- stateWritePath "frecency.json"
      writeFile new "{}"
      stateReadPath "frecency.json" `shouldReturn` new

  it "migrates a legacy file once, leaving it in place" $
    withTempHome $ \home -> do
      let legacy = home </> ".trha" </> "history"
      createDirectoryIfMissing True (home </> ".trha")
      writeFile legacy "old entry\n"
      migrateLegacy "history"
      new <- stateWritePath "history"
      readFile new `shouldReturn` "old entry\n"
      doesFileExist legacy `shouldReturn` True

  it "returns the new path when nothing exists yet" $
    withTempHome $ \home -> do
      path <- stateReadPath "stash.jsonl"
      path `shouldBe` home </> ".trha" </> "state" </> "stash.jsonl"

-- | Point @HOME@ at a scratch directory for one test, then put it back.
withTempHome :: (FilePath -> IO a) -> IO a
withTempHome action = bracket acquire release (\(dir, _) -> action dir)
  where
    acquire = do
      base <- getTemporaryDirectory
      let dir = base </> "trha-statepaths-spec"
      removePathForcibly dir
      createDirectoryIfMissing True dir
      saved <- lookupEnv "HOME"
      setEnv "HOME" dir
      pure (dir, saved)
    release (dir, saved) = do
      case saved of
        Just home -> setEnv "HOME" home
        Nothing   -> unsetEnv "HOME"
      removePathForcibly dir
