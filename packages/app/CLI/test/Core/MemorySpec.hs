{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Core.MemorySpec (spec) where

import Control.Exception (IOException, catch)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
    ( createDirectoryIfMissing, getTemporaryDirectory, removePathForcibly )
import System.FilePath ((</>))
import System.Process (getCurrentPid)
import Test.Hspec

import Core.Memory (memoryFiles)

spec :: Spec
spec = describe "memoryFiles" $ do
  it "reads every non-empty .md file, sorted by name" $
    withScratch $ \dir -> do
      TIO.writeFile (dir </> "b.md") "- second\n"
      TIO.writeFile (dir </> "a.md") "- first\n"
      TIO.writeFile (dir </> "empty.md") "\n \n"
      TIO.writeFile (dir </> "ignored.txt") "not a note"
      entries <- memoryFiles dir
      map fst entries `shouldBe` ["a.md", "b.md"]
      map snd entries `shouldBe` ["- first\n", "- second\n"]

  it "returns nothing for a missing directory" $
    withScratch $ \dir -> do
      entries <- memoryFiles (dir </> "nope")
      entries `shouldBe` []

-- | Private scratch directory for this process, removed afterwards.
withScratch :: (FilePath -> IO a) -> IO a
withScratch act = do
  tmp <- getTemporaryDirectory
  pid <- getCurrentPid
  let dir = tmp </> ("trha-memory-spec-" ++ show pid)
  ignore (removePathForcibly dir)
  createDirectoryIfMissing True dir
  result <- act dir
  ignore (removePathForcibly dir)
  pure result
  where
    ignore io = io `catch` \(_ :: IOException) -> pure ()
