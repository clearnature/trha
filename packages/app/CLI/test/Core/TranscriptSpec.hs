{-# LANGUAGE OverloadedStrings #-}

module Core.TranscriptSpec (spec) where

import Test.Hspec
import Core.Transcript (EventKind(..), allEventKinds, eventKindName, eventRegistry, legacyEventName, makeEnvelope)
import Data.Aeson (Value(..), (.=), object, (.:), (.:?))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson as Aeson
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "makeEnvelope" $ do
    it "carries the version, id, ts and event type" $ do
      let e = makeEnvelope "user" "2026-09-05T00:00:00Z" "id-1" [ "content" .= ("hi" :: String) ]
      case e of
        Object o -> do
          KM.lookup "v" o `shouldBe` Just (Number 1)
          KM.lookup "id" o `shouldBe` Just (String "id-1")
          KM.lookup "ts" o `shouldBe` Just (String "2026-09-05T00:00:00Z")
          KM.lookup "event" o `shouldBe` Just (String "user")
          KM.lookup "content" o `shouldBe` Just (String "hi")
        _ -> expectationFailure "expected an object"
    it "keeps payload keys flat alongside the envelope fields" $ do
      let e = makeEnvelope "tool" "t" "i" [ "tool" .= ("read_file" :: String), "args" .= ([ "a" ] :: [String]) ]
      case e of
        Object o -> KM.size o `shouldBe` 6
        _ -> expectationFailure "expected an object"
    it "round-trips through Aeson" $ do
      let e = makeEnvelope "done" "t" "i" [ "usage" .= object [ "total" .= (10 :: Int) ] ]
      Aeson.eitherDecode (Aeson.encode e) `shouldBe` Right e

  describe "event registry" $ do
    it "has one canonical name per kind, unique and described" $ do
      let names = map fst eventRegistry
      map eventKindName allEventKinds `shouldBe` names
      map fst eventRegistry `shouldSatisfy` uniqueKinds
      map snd eventRegistry `shouldSatisfy` all (not . T.null)
    it "covers every writer type used by the record functions" $ do
      -- the six writer types (session/user/assistant/tool/done/error) are
      -- exactly the registry rows
      length eventRegistry `shouldBe` 7
    it "maps legacy aliases to canonical names" $ do
      legacyEventName "tool_call" `shouldBe` "tool"
      legacyEventName "user" `shouldBe` "user"
  where
    uniqueKinds xs = length xs == length (foldr step [] xs)
    step x acc = if x `elem` acc then acc else x : acc
