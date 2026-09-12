{-# LANGUAGE OverloadedStrings #-}

module Core.TypesSpec (spec) where

import Test.Hspec
import Core.Types (ToolEvent(..), ToolRunStatus(..))
import Data.Aeson (Result(..), Value(..), object, toJSON, (.=), fromJSON)
import Data.Aeson.Types (Pair)
import Data.Text (Text)

toolEv :: [Pair] -> Value
toolEv = object

spec :: Spec
spec = do
  describe "ToolEvent FromJSON" $ do
    it "decodes a running event" $ do
      fromJSON (toolEv [ "name" .= ("bash" :: String)
                       , "args" .= (["ls", "-la"] :: [Text])
                       , "status" .= ("running" :: Text)
                       ]) `shouldBe`
        Success (ToolEvent "bash" ["ls", "-la"] ToolRunRunning Nothing)

    it "decodes a succeeded event with duration" $ do
      fromJSON (toolEv [ "name" .= ("bash" :: String)
                       , "status" .= ("succeeded" :: Text)
                       , "durationMs" .= (12 :: Int)
                       ]) `shouldBe`
        Success (ToolEvent "bash" [] ToolRunSucceeded (Just 12))

    it "decodes a failed event with an error detail" $ do
      fromJSON (toolEv [ "name" .= ("bash" :: String)
                       , "status" .= ("failed" :: Text)
                       , "error" .= ("exit 1" :: Text)
                       ]) `shouldBe`
        Success (ToolEvent "bash" [] (ToolRunFailed "exit 1") Nothing)

    it "rejects unknown statuses" $ do
      (fromJSON (toolEv [ "name" .= ("bash" :: String)
                        , "status" .= ("mystery" :: Text)
                        ]) :: Result ToolEvent)
        `shouldSatisfy` \r -> case r of
          Success _ -> False
          Error _   -> True

    it "defaults missing args to an empty list" $ do
      fromJSON (toolEv [ "name" .= ("x" :: String), "status" .= ("running" :: Text) ])
        `shouldBe` Success (ToolEvent "x" [] ToolRunRunning Nothing)

  describe "ToolEvent ToJSON/FromJSON roundtrip" $ do
    it "survives a roundtrip for a failed event with error" $ do
      let ev = ToolEvent "bash" ["ls"] (ToolRunFailed "exit 1") (Just 3)
      fromJSON (toJSON ev) `shouldBe` Success ev

    it "survives a roundtrip for a succeeded event" $ do
      let ev = ToolEvent "bash" [] ToolRunSucceeded (Just 12)
      fromJSON (toJSON ev) `shouldBe` Success ev
