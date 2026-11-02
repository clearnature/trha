{-# LANGUAGE OverloadedStrings #-}

module Core.ProjectStoreSpec (spec) where

import qualified Data.Text as T
import System.Directory
    ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist )
import System.FilePath ((</>))
import Test.Hspec
import TestHome (withTempHome)
import Config.Settings (getConfigDir)

import Core.ProjectStore
    ( ProjectSession(..), ensureProject, projectDir, projectSessions
    , projectSlug, recordProjectSession )
import Core.SessionSummary (SessionSummary(..))

summary :: String -> String -> SessionSummary
summary sid title = SessionSummary sid (T.pack title) 1 (Just "deepseek-flash")
  (Just "2026-10-27T00:00:00Z") Nothing Nothing

spec :: Spec
spec = do
  describe "projectSlug" $ do
    it "maps every / to - (Claude Code rule)" $
      projectSlug "/home/u/proj" `shouldBe` "-home-u-proj"

  describe "ensureProject" $
    it "creates the project directory and meta.json" $
      withTempHome $ \home -> do
        let root = home </> "proj"
        ensureProject root
        dir <- projectDir root
        doesDirectoryExist dir `shouldReturn` True
        doesFileExist (dir </> "meta.json") `shouldReturn` True

  describe "recordProjectSession" $ do
    it "indexes a session and updates a renamed one in place" $
      withTempHome $ \home -> do
        -- Isolation means the data directory, not environment variables:
        -- Windows resolves getHomeDirectory through Win32, so HOME is not the
        -- contract getConfigDir honours.
        cfgDir <- getConfigDir
        cfgDir `shouldBe` (home </> ".trha")
        let root = home </> "proj"
        recordProjectSession root (summary "s1" "First")
        recordProjectSession root (summary "s2" "Second")
        rows <- projectSessions root
        map psId rows `shouldBe` ["s1", "s2"]
        recordProjectSession root (summary "s1" "Renamed")
        rows2 <- projectSessions root
        map psTitle rows2 `shouldBe` ["Renamed", "Second"]

    it "keeps different projects apart" $
      withTempHome $ \home -> do
        let a = home </> "a"
            b = home </> "b"
        recordProjectSession a (summary "sa" "A")
        recordProjectSession b (summary "sb" "B")
        map psId <$> projectSessions a `shouldReturn` ["sa"]
        map psId <$> projectSessions b `shouldReturn` ["sb"]

-- | Point @HOME@ at a scratch directory for one test, then put it back.

