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
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removePathForcibly)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>), takeDirectory)
import Test.Hspec

import Config.Settings (getHomeConfigPath, resolveConfig)
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
