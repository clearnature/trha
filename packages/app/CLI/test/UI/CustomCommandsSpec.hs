{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module UI.CustomCommandsSpec (spec) where

import Control.Exception (IOException, catch)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
    ( createDirectoryIfMissing, getTemporaryDirectory, removePathForcibly )
import System.FilePath ((</>))
import System.Process (getCurrentPid)
import Test.Hspec

import UI.Commands.Registry (Command(..), parseCommandWith)
import UI.CustomCommands
    ( CustomCommand(..), loadCustomCommandsFrom, parseCommandFile
    , renderCustomCommand )

spec :: Spec
spec = do
  describe "parseCommandFile" $ do
    it "takes the first heading as the description" $ do
      let parsed = parseCommandFile "review" "# Review a diff\n\nLook at $ARGUMENTS closely."
      fmap ccName parsed `shouldBe` Just "review"
      fmap ccDescription parsed `shouldBe` Just "Review a diff"
      fmap (T.strip . ccTemplate) parsed `shouldBe` Just "Look at $ARGUMENTS closely."

    it "accepts a file without a description" $ do
      let parsed = parseCommandFile "note" "Write a note."
      fmap ccDescription parsed `shouldBe` Just ""

    it "rejects invalid names and empty bodies" $ do
      parseCommandFile "bad name" "x" `shouldBe` Nothing
      parseCommandFile "" "x" `shouldBe` Nothing
      parseCommandFile "empty" "# only a title\n" `shouldBe` Nothing

  describe "renderCustomCommand" $ do
    let cc = CustomCommand "review" "" "Review this: $ARGUMENTS"
    it "replaces the placeholder" $
      renderCustomCommand cc "src/A.hs" `shouldBe` "Review this: src/A.hs"
    it "appends arguments when there is no placeholder" $
      renderCustomCommand (CustomCommand "x" "" "Do the thing.") "extra"
        `shouldBe` "Do the thing.\n\nextra"
    it "keeps the template alone without arguments" $
      renderCustomCommand (CustomCommand "x" "" "Do the thing.") "  "
        `shouldBe` "Do the thing."

  describe "loadCustomCommandsFrom" $ do
    it "reads *.md files and lets the later directory win" $
      withDirs $ \[proj, home] -> do
        TIO.writeFile (proj </> "review.md") "project version"
        TIO.writeFile (proj </> "notes.txt") "ignored"
        TIO.writeFile (home </> "review.md") "user version"
        TIO.writeFile (home </> "deploy.md") "# Deploy\n\nShip it."
        cmds <- loadCustomCommandsFrom [proj, home]
        map ccName cmds `shouldBe` ["review", "deploy"]
        fmap ccTemplate cmds `shouldBe` ["user version", "Ship it.\n"]

  describe "parseCommandWith" $ do
    it "recognises a user command and keeps its arguments" $ do
      parseCommandWith ["review"] "/review src/A.hs"
        `shouldBe` RunCustom "review" "src/A.hs"
    it "falls through to the built-in registry" $ do
      parseCommandWith ["review"] "/model deepseek-chat"
        `shouldBe` SelectModel "deepseek-chat"

-- | Two scratch directories for this process, removed afterwards.
withDirs :: ([FilePath] -> IO a) -> IO a
withDirs act = do
  tmp <- getTemporaryDirectory
  pid <- getCurrentPid
  let base = tmp </> ("trha-customcmds-spec-" ++ show pid)
      dirs = [base </> "project", base </> "home"]
  ignore (removePathForcibly base)
  mapM_ (createDirectoryIfMissing True) dirs
  result <- act dirs
  ignore (removePathForcibly base)
  pure result
  where
    ignore io = io `catch` \(_ :: IOException) -> pure ()
