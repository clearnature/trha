{-# LANGUAGE OverloadedStrings #-}

module Core.StatePathsSpec (spec) where

import System.Directory
    ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist )
import System.FilePath ((</>))
import Test.Hspec
import TestHome (withTempHome)

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


