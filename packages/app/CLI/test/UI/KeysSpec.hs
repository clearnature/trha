{-# LANGUAGE OverloadedStrings #-}

module UI.KeysSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import UI.Keys

spec :: Spec
spec = do
  describe "leaderResolve" $ do
    it "maps every documented key" $ do
      leaderResolve 'b' `shouldBe` Just LeaderSidebar
      leaderResolve 'p' `shouldBe` Just LeaderProvider
      leaderResolve 'm' `shouldBe` Just LeaderModels
      leaderResolve 's' `shouldBe` Just LeaderSessions
      leaderResolve ',' `shouldBe` Just LeaderSettings
      leaderResolve '?' `shouldBe` Just LeaderHelp
      leaderResolve 'i' `shouldBe` Just LeaderInterrupt

    it "cancels on an unbound key" $ do
      leaderResolve 'z' `shouldBe` Nothing

  describe "leaderHelp" $ do
    it "names every binding" $ do
      let keys = [ "b sidebar", "p provider", "m models", "s sessions", ", settings"
                 , "? help", "i interrupt", "esc cancel" ] :: [T.Text]
      mapM_ (\k -> leaderHelp `shouldSatisfy` T.isInfixOf k) keys

  describe "decideCtrlC (terminal convention)" $ do
    let t0 = read "2026-10-27 00:00:00 UTC" :: UTCTime
        t2 = read "2026-10-27 00:00:02 UTC" :: UTCTime
        t9 = read "2026-10-27 00:00:09 UTC" :: UTCTime

    it "interrupts a running turn before doing anything else" $ do
      decideCtrlC True True (Just t0) t2 `shouldBe` CtrlCInterrupt
      decideCtrlC True False Nothing t2 `shouldBe` CtrlCInterrupt

    it "clears a non-empty prompt" $
      decideCtrlC False True Nothing t2 `shouldBe` CtrlCClearInput

    it "arms on the first idle Ctrl+C and quits on the second within 3s" $ do
      decideCtrlC False False Nothing t0 `shouldBe` CtrlCArmQuit
      decideCtrlC False False (Just t0) t2 `shouldBe` CtrlCQuit

    it "re-arms after the window expires" $
      decideCtrlC False False (Just t0) t9 `shouldBe` CtrlCArmQuit

  describe "decideCtrlD" $ do
    it "quits only from an idle empty prompt" $ do
      decideCtrlD False False `shouldBe` True
      decideCtrlD True False `shouldBe` False
      decideCtrlD False True `shouldBe` False
