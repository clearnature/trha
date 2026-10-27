{-# LANGUAGE OverloadedStrings #-}

module UI.IndexCacheSpec (spec) where

import Control.Exception (bracket)
import Data.Time.Clock (addUTCTime, getCurrentTime)
import System.Directory
    ( createDirectoryIfMissing, getTemporaryDirectory, listDirectory
    , removePathForcibly )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import Test.Hspec

import UI.Completion (Completion(..), defaultIndexOptions)
import UI.IndexCache
    ( CacheFile(..), cacheTtlSeconds, fnv1a, isFresh, scanProjectCached )

spec :: Spec
spec = do
  describe "fnv1a" $ do
    it "is stable and distinguishes paths" $ do
      fnv1a "/a/b" `shouldBe` fnv1a "/a/b"
      fnv1a "/a/b" `shouldNotBe` fnv1a "/a/c"

  describe "isFresh" $ do
    it "accepts a recent entry whose root mtime is unchanged" $ do
      now <- getCurrentTime
      isFresh now now (CacheFile "/w" now now []) `shouldBe` True
    it "rejects an expired entry" $ do
      now <- getCurrentTime
      let old = addUTCTime (fromIntegral (-cacheTtlSeconds - 1)) now
      isFresh now now (CacheFile "/w" old now []) `shouldBe` False
    it "rejects a changed root mtime" $ do
      now <- getCurrentTime
      isFresh now (addUTCTime 5 now) (CacheFile "/w" now now []) `shouldBe` False

  describe "scanProjectCached" $
    it "writes one cache file and reuses it on the next call" $
      withTempHome $ \home -> do
        let root = home </> "proj"
        createDirectoryIfMissing True (root </> "src")
        writeFile (root </> "src" </> "A.hs") ""
        first <- scanProjectCached defaultIndexOptions root
        first `shouldSatisfy` any ((== "src/A.hs") . compPath)
        names <- listDirectory (home </> ".trha" </> "cache")
        length names `shouldBe` 1
        second <- scanProjectCached defaultIndexOptions root
        second `shouldBe` first

-- | Point @HOME@ at a scratch directory for one test, then put it back.
withTempHome :: (FilePath -> IO a) -> IO a
withTempHome action = bracket acquire release (\(dir, _) -> action dir)
  where
    acquire = do
      base <- getTemporaryDirectory
      let dir = base </> "trha-indexcache-spec"
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
