{-# LANGUAGE OverloadedStrings #-}

module Core.TypesSpec (spec) where

import Test.Hspec
import Core.Types
  ( ToolEvent(..), ToolRunStatus(..), PlanView(..), PlanStepView(..)
  , splitPlanSteps, parsePlanView, planStepOut, renderPlanBrief )
import Data.Aeson (Result(..), Value(..), object, toJSON, (.=), fromJSON)
import Data.Aeson.Types (Pair)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

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
