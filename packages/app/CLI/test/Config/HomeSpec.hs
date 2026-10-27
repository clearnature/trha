{-# LANGUAGE ScopedTypeVariables #-}

module Config.HomeSpec (spec) where

import Test.Hspec
import Config.Home (homeLayout, initHomeDirs)
import Control.Exception (IOException, catch)
import Control.Monad (forM_)
import Data.Bits ((.&.))
import Data.List (nub)
import System.Directory
    ( createDirectoryIfMissing, doesDirectoryExist, getTemporaryDirectory
    , removeDirectoryRecursive )
import System.FilePath ((</>))
import System.Posix.Files (fileMode, getFileStatus)
import System.Posix.Process (getProcessID)

spec :: Spec
spec = do
  describe "homeLayout" $ do
    it "covers the reference CLIs' categories" $ do
      let want = [ "sessions", "scheduler-state", "skills", "agents"
                 , "commands", "rules", "plans", "projects", "logs", "cache"
                 , "memories", "backups", "file-history", "state"
                 , "paste", "voice", "exports" ]
      want `shouldSatisfy` all (`elem` homeLayout)
    it "has no duplicate entries" $
      length homeLayout `shouldBe` length (nub homeLayout)

  describe "initHomeDirs" $
    it "creates every directory 0700, reports them once, and is idempotent" $
      withScratch $ \root -> do
        created <- initHomeDirs root
        created `shouldMatchList` homeLayout
        again <- initHomeDirs root
        again `shouldBe` []
        forM_ homeLayout $ \sub -> do
          let dir = root </> sub
          doesDirectoryExist dir `shouldReturn` True
          mode <- fileMode <$> getFileStatus dir
          (mode .&. 0o777) `shouldBe` 0o700

-- | Private scratch directory for this process, removed afterwards.
withScratch :: (FilePath -> IO a) -> IO a
withScratch act = do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let root = tmp </> ("trha-home-spec-" ++ show pid)
  ignore (removeDirectoryRecursive root)
  createDirectoryIfMissing True root
  result <- act root
  ignore (removeDirectoryRecursive root)
  pure result
  where
    ignore io = io `catch` \(_ :: IOException) -> pure ()
