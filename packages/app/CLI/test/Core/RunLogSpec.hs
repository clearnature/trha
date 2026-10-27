{-# LANGUAGE OverloadedStrings #-}

module Core.RunLogSpec (spec) where

import Control.Exception (bracket)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
    ( createDirectoryIfMissing, getTemporaryDirectory, listDirectory
    , removePathForcibly )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import Test.Hspec

import Core.RunLog (logLine)

spec :: Spec
spec = describe "logLine" $
  it "appends one stamped line per call to today's log" $
    withLogDir $ \dir -> do
      logLine "first"
      logLine "second"
      names <- listDirectory dir
      length names `shouldBe` 1
      body <- TIO.readFile (dir </> head names)
      let entries = T.lines body
      length entries `shouldBe` 2
      entries !! 0 `shouldSatisfy` T.isSuffixOf " first"
      entries !! 1 `shouldSatisfy` T.isSuffixOf " second"

-- | Point @TRHA_LOG_DIR@ at a scratch directory for one test, then put it
-- back (@~/.trha/logs@ must not receive test noise).
withLogDir :: (FilePath -> IO a) -> IO a
withLogDir action = bracket acquire release (\(dir, _) -> action dir)
  where
    acquire = do
      base <- getTemporaryDirectory
      let dir = base </> "trha-runlog-spec"
      removePathForcibly dir
      createDirectoryIfMissing True dir
      saved <- lookupEnv "TRHA_LOG_DIR"
      setEnv "TRHA_LOG_DIR" dir
      pure (dir, saved)
    release (dir, saved) = do
      case saved of
        Just value -> setEnv "TRHA_LOG_DIR" value
        Nothing    -> unsetEnv "TRHA_LOG_DIR"
      removePathForcibly dir
