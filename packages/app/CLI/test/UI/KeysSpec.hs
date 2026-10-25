{-# LANGUAGE OverloadedStrings #-}

module UI.KeysSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
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
