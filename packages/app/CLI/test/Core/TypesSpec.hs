{-# LANGUAGE OverloadedStrings #-}

module Core.TypesSpec (spec) where

import Test.Hspec
import Core.Types
  ( ToolEvent(..), ToolRunStatus(..), PlanView(..), PlanStepView(..)
  , ProviderInfo(..), ModelInfo(..), Usage(..), mkUsage
  , providerStoreToList, providerModelInfos, modelForProvider
  , splitPlanSteps, parsePlanView, planStepOut, renderPlanBrief
  , defaultCLIConfig, configMouseCapture, effectiveReasoningLanguage
  , configLang, configReasoningLanguage )
import Data.Aeson (Result(..), Value(..), object, toJSON, (.=), fromJSON)
import Data.Aeson.Types (Pair)
import Data.Either (isLeft)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

toolEv :: [Pair] -> Value
toolEv = object

spec :: Spec
spec = do
  describe "defaultCLIConfig" $
    it "captures the mouse by default" $
      configMouseCapture defaultCLIConfig `shouldBe` False

  describe "effectiveReasoningLanguage" $ do
    it "follows the interface language when the setting is auto" $
      effectiveReasoningLanguage defaultCLIConfig `shouldBe` Just "zh-Hans"
    it "follows an explicit interface language (en UI -> English)" $
      effectiveReasoningLanguage defaultCLIConfig { configLang = "en" } `shouldBe` Just "en"
    it "lets an explicit reasoning language win over the interface" $
      effectiveReasoningLanguage defaultCLIConfig
        { configLang = "zh-Hans", configReasoningLanguage = "en" } `shouldBe` Just "en"
    it "treats auto case-insensitively and ignores surrounding space" $
      effectiveReasoningLanguage defaultCLIConfig
        { configReasoningLanguage = "  AUTO " } `shouldBe` Just "zh-Hans"
    it "sends nothing when both fields are empty" $
      effectiveReasoningLanguage defaultCLIConfig
        { configLang = "", configReasoningLanguage = "" } `shouldBe` Nothing

  describe "ToolEvent FromJSON" $ do
    it "decodes a running event" $ do
      fromJSON (toolEv [ "name" .= ("bash" :: String)
                       , "args" .= (["ls", "-la"] :: [Text])
                       , "status" .= ("running" :: Text)
                       ]) `shouldBe`
        Success (ToolEvent "bash" ["ls", "-la"] ToolRunRunning Nothing Nothing)

    it "decodes a succeeded event with duration" $ do
      fromJSON (toolEv [ "name" .= ("bash" :: String)
                       , "status" .= ("succeeded" :: Text)
                       , "durationMs" .= (12 :: Int)
                       ]) `shouldBe`
        Success (ToolEvent "bash" [] ToolRunSucceeded (Just 12) Nothing)

    it "decodes an output preview" $ do
      fromJSON (toolEv [ "name" .= ("bash" :: String)
                       , "status" .= ("succeeded" :: Text)
                       , "output" .= ("line1\nline2" :: Text)
                       ]) `shouldBe`
        Success (ToolEvent "bash" [] ToolRunSucceeded Nothing (Just "line1\nline2"))

    it "decodes a failed event with an error detail" $ do
      fromJSON (toolEv [ "name" .= ("bash" :: String)
                       , "status" .= ("failed" :: Text)
                       , "error" .= ("exit 1" :: Text)
                       ]) `shouldBe`
        Success (ToolEvent "bash" [] (ToolRunFailed "exit 1") Nothing Nothing)

    it "rejects unknown statuses" $ do
      (fromJSON (toolEv [ "name" .= ("bash" :: String)
                        , "status" .= ("mystery" :: Text)
                        ]) :: Result ToolEvent)
        `shouldSatisfy` \r -> case r of
          Success _ -> False
          Error _   -> True

    it "defaults missing args to an empty list" $ do
      fromJSON (toolEv [ "name" .= ("x" :: String), "status" .= ("running" :: Text) ])
        `shouldBe` Success (ToolEvent "x" [] ToolRunRunning Nothing Nothing)

  describe "ToolEvent ToJSON/FromJSON roundtrip" $ do
    it "survives a roundtrip for a failed event with error" $ do
      let ev = ToolEvent "bash" ["ls"] (ToolRunFailed "exit 1") (Just 3) (Just "boom\nmore")
      fromJSON (toJSON ev) `shouldBe` Success ev

    it "survives a roundtrip for a succeeded event" $ do
      let ev = ToolEvent "bash" [] ToolRunSucceeded (Just 12) (Just "out")
      fromJSON (toJSON ev) `shouldBe` Success ev

  describe "plan input" $ do
    it "splits steps on semicolons and newlines, dropping blanks" $ do
      splitPlanSteps "a; b ;  c" `shouldBe` ["a", "b", "c"]
      splitPlanSteps "a\nb\n\nc" `shouldBe` ["a", "b", "c"]
      splitPlanSteps "only one" `shouldBe` ["only one"]
      splitPlanSteps "  " `shouldBe` []

  describe "plan view parsing" $ do
    let kernelAnswer = object
          [ "plan" .= object
              [ "id" .= ("p#plan" :: Text)
              , "mode" .= ("stepwise" :: Text)
              , "steps" .=
                  [ object [ "id" .= ("s1" :: Text), "title" .= ("one" :: Text), "status" .= ("done" :: Text) ]
                  , object [ "id" .= ("s2" :: Text), "title" .= ("two" :: Text), "status" .= ("approved" :: Text) ]
                  , object [ "id" .= ("s3" :: Text), "title" .= ("three" :: Text), "status" .= ("pending" :: Text) ]
                  ]
              ]
          , "pending" .= object [ "id" .= ("s3" :: Text), "title" .= ("three" :: Text) ]
          , "agentState" .= object [ "state" .= ("executing_step" :: Text), "step" .= ("s2" :: Text) ]
          ]

    it "reads steps, the pending step and the phase" $ do
      parsePlanView kernelAnswer `shouldBe` Just PlanView
        { pvId = "p#plan"
        , pvSteps =
            [ PlanStepView "s1" "one" "done"
            , PlanStepView "s2" "two" "approved"
            , PlanStepView "s3" "three" "pending"
            ]
        , pvPending = Just "s3"
        , pvPhase = "executing_step"
        }

    it "finds the step that is out with the host" $ do
      let pv = fromMaybe (error "unparsed") (parsePlanView kernelAnswer)
      fmap psvId (planStepOut pv) `shouldBe` Just "s2"
      -- not executing -> nothing is out
      fmap psvId (planStepOut pv { pvPhase = "planning" }) `shouldBe` Nothing

    it "renders a brief that marks status and the pending step" $ do
      let pv = fromMaybe (error "unparsed") (parsePlanView kernelAnswer)
          out = renderPlanBrief pv
      out `shouldSatisfy` T.isInfixOf "[x] one"
      out `shouldSatisfy` T.isInfixOf "[+] two"
      out `shouldSatisfy` T.isInfixOf "pending"

    it "rejects nonsense instead of fabricating a plan" $ do
      parsePlanView (String "nope") `shouldBe` Nothing
      parsePlanView (object []) `shouldBe` Nothing

  describe "provider registry" $ do
    let wire = object
          [ "providers" .=
              [ object
                  [ "name" .= ("deepseek" :: Text)
                  , "kind" .= ("openai" :: Text)
                  , "baseUrl" .= ("https://api.deepseek.com" :: Text)
                  , "models" .= (["deepseek-flash", "deepseek-v4-pro"] :: [Text])
                  , "default" .= ("deepseek-flash" :: Text)
                  , "inUse" .= True
                  , "hasKey" .= True
                  , "contextWindow" .= (1000000 :: Int)
                  ]
              ]
          ]

    it "parses the providers envelope" $ do
      case providerStoreToList wire of
        Right [p] -> do
          piName p `shouldBe` "deepseek"
          piKind p `shouldBe` "openai"
          piBaseUrl p `shouldBe` "https://api.deepseek.com"
          piModels p `shouldBe` ["deepseek-flash", "deepseek-v4-pro"]
          piDefault p `shouldBe` "deepseek-flash"
          piInUse p `shouldBe` True
          piHasKey p `shouldBe` True
          piContextWindow p `shouldBe` Just 1000000
        other -> expectationFailure ("expected one provider, got " <> show other)

    it "defaults the optional fields" $ do
      let minimal = object ["providers" .= [object ["name" .= ("p" :: Text)]]]
      case providerStoreToList minimal of
        Right [p] -> do
          piKind p `shouldBe` "openai"
          piBaseUrl p `shouldBe` ""
          piModels p `shouldBe` []
          piInUse p `shouldBe` False
          piHasKey p `shouldBe` False
          piContextWindow p `shouldBe` Nothing
        other -> expectationFailure ("expected a provider, got " <> show other)

    it "reports a malformed envelope instead of an empty registry" $ do
      providerStoreToList (object []) `shouldSatisfy` isLeft
      providerStoreToList (String "x") `shouldSatisfy` isLeft

    it "turns a provider's models into picker rows with its context window" $ do
      let p = ProviderInfo "deepseek" "openai" "https://x" ["a", "b"] "a" True True (Just 4096) "" True False [] [] Nothing Nothing "" ""
      map modelName (providerModelInfos p) `shouldBe` ["a", "b"]
      map modelContextSize (providerModelInfos p) `shouldBe` [4096, 4096]

    it "keeps a model the provider offers, else falls back to its default" $ do
      let p = ProviderInfo "deepseek" "openai" "https://x" ["deepseek-flash", "deepseek-v4-pro"]
                                "deepseek-flash" True True Nothing "" True False [] [] Nothing Nothing "" ""
      modelForProvider p "deepseek-v4-pro" `shouldBe` "deepseek-v4-pro"
      modelForProvider p "gpt-4" `shouldBe` "deepseek-flash"

  describe "Usage FromJSON" $ do
    it "uses cumulativeTokens when the scheduler omits totalTokens" $ do
      let v = object
            [ "promptTokens" .= (10 :: Int)
            , "completionTokens" .= (5 :: Int)
            , "cacheHitTokens" .= (0 :: Int)
            , "cacheMissTokens" .= (10 :: Int)
            , "cumulativeTokens" .= (99 :: Int) ]
      case fromJSON v of
        Success u -> u `shouldBe` Usage 10 5 99 0 10 0
        Error e -> expectationFailure e

    it "derives prompt+completion when no total is present" $ do
      let v = object [ "promptTokens" .= (10 :: Int), "completionTokens" .= (5 :: Int) ]
      case fromJSON v of
        Success u -> u `shouldBe` mkUsage 10 5 15
        Error e -> expectationFailure e

    it "still accepts the full shape" $ do
      let v = object
            [ "promptTokens" .= (1 :: Int), "completionTokens" .= (2 :: Int)
            , "totalTokens" .= (3 :: Int) ]
      case fromJSON v of
        Success u -> u `shouldBe` mkUsage 1 2 3
        Error e -> expectationFailure e

