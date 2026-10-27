{-# LANGUAGE OverloadedStrings #-}

-- | Settings resolution: a blank saved field must not win over the default.
--
-- Regression: an older build wrote @configModel: ''@. The file exists, so it is
-- never rewritten, and the blank model survived every upgrade — the TUI footer
-- read @模型：@ with nothing after it and requests carried @model: ""@.
module Config.SettingsSpec (spec) where

import Control.Exception (bracket)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory
    ( createDirectoryIfMissing, getTemporaryDirectory, listDirectory
    , removePathForcibly )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>), takeDirectory)
import Test.Hspec

import Config.Settings (backupKeep, getHomeConfigPath, resolveConfig, saveConfig)
import Core.Types (CLIConfig(..), defaultCLIConfig)

-- | Point @HOME@ at a scratch directory for one test, then put it back.
withTempHome :: (FilePath -> IO a) -> IO a
withTempHome action = bracket acquire release (\(dir, _) -> action dir)
  where
    acquire = do
      base <- getTemporaryDirectory
      let dir = base </> "trha-settings-spec"
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

spec :: Spec
spec = describe "settings resolution" $ do

  it "falls back to the default model when the file has an empty one" $
    withTempHome $ \_ -> do
      path <- getHomeConfigPath
      createDirectoryIfMissing True (takeDirectory path)
      writeFile path "configModel: ''\nconfigHost: localhost\n"
      config <- resolveConfig defaultCLIConfig
      configModel config `shouldBe` configModel defaultCLIConfig
      configModel config `shouldSatisfy` (not . T.null)

  it "keeps a real value from the file" $
    withTempHome $ \_ -> do
      path <- getHomeConfigPath
      createDirectoryIfMissing True (takeDirectory path)
      writeFile path "configModel: deepseek-flash\n"
      config <- resolveConfig defaultCLIConfig
      configModel config `shouldBe` ("deepseek-flash" :: Text)

  it "keeps a rollback copy of the previous settings file" $
    withTempHome $ \home -> do
      saveConfig defaultCLIConfig
      saveConfig defaultCLIConfig { configModel = "deepseek-flash" }
      names <- listDirectory (home </> ".trha" </> "backups")
      names `shouldSatisfy` (not . null)
      previous <- readFile (home </> ".trha" </> "backups" </> head names)
      T.length (T.pack previous) `shouldSatisfy` (> 0)

  it "prunes rollback copies beyond backupKeep" $
    withTempHome $ \home -> do
      let bdir = home </> ".trha" </> "backups"
      createDirectoryIfMissing True bdir
      mapM_ (\i -> writeFile (bdir </> ("settings-20200101-0000" <> show (i :: Int) <> ".yaml")) "x") [1 .. 12]
      path <- getHomeConfigPath
      createDirectoryIfMissing True (takeDirectory path)
      writeFile path "configModel: deepseek-flash\n"
      saveConfig defaultCLIConfig
      names <- listDirectory bdir
      length names `shouldBe` backupKeep
