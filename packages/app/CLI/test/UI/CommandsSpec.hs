{-# LANGUAGE OverloadedStrings #-}

module UI.CommandsSpec (spec) where

import Test.Hspec
import UI.Commands.Registry
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "parseCommand" $ do
    it "parses every registered command to a real command" $ do
      mapM_ (\sc -> parseCommand (scCommand sc) `shouldSatisfy` isReal) slashRegistry

    it "parses every picker candidate to a non-message command" $ do
      mapM_ (\p -> parseCommand p `shouldSatisfy` isReal)
        [ scCommand sc | sc <- slashRegistry, scPicker sc ]

    it "handles parameterised commands" $ do
      parseCommand "/model deepseek-chat" `shouldBe` SelectModel "deepseek-chat"
      parseCommand "/delete abc" `shouldBe` DeleteSession "abc"

    it "handles bare parameterised commands" $ do
      parseCommand "/model" `shouldBe` ShowModel
      parseCommand "/delete" `shouldBe` DeleteSession ""

    it "treats unknown slash commands as Unknown (never a message)" $ do
      parseCommand "/foo" `shouldBe` Unknown "/foo"
      parseCommand "/foobar x" `shouldBe` Unknown "/foobar"

    it "sends ordinary text as a message" $ do
      parseCommand "hello world" `shouldBe` SendMessage "hello world"

    it "handles empty and whitespace input" $ do
      parseCommand "" `shouldBe` SendMessage ""
      parseCommand "   " `shouldBe` SendMessage "   "

    it "parses /plugins" $ do
      parseCommand "/plugins" `shouldBe` Plugins

    it "parses /resume forms" $ do
      parseCommand "/resume" `shouldBe` ResumeList
      parseCommand "/resume 2" `shouldBe` ResumeSelect "2"
      parseCommand "/resume session-abc" `shouldBe` ResumeSelect "session-abc"

    it "treats /exit as quit" $ do
      parseCommand "/exit" `shouldBe` Quit

isReal :: Command -> Bool
isReal c = case c of
  SendMessage _ -> False
  Unknown _     -> False
  _             -> True
