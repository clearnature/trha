-- | 多步计划：逐步批准的状态机与线上契约。
--
-- 分工是这套设计的前提：宿主产生步骤、执行步骤；内核只回答「这一条现在可以
-- 跑吗」和「跑到哪了」。所以这里既要测合法迁移，也要测**非法**动作什么都不做
-- （重复批准、回报没放行的步、计划进行中插一个对话步）。
{-# LANGUAGE OverloadedStrings #-}

module PlanSpec (planSpec) where

import Control.Exception (bracket)
import Data.Aeson (Value (..), encode, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Network.HTTP.Client
import Network.HTTP.Types (statusCode)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import System.Directory
import System.FilePath ((</>))
import Test.Hspec

import API.Server (mkStubApp)
import Core.Agent.StateMachine
  ( AgentCommand (..), markApproved, markReported, markRejected, markSkipped
  , pendingStep, planFinished, transition )
import Core.Agent.Types
import Core.Session.Manager
import Core.Session.Types
import qualified Infrastructure.Storage.SessionStore as SS

withScratch :: (FilePath -> IO a) -> IO a
withScratch act = bracket acquire release act
  where
    root = "trha-plan-spec"
    acquire = do
      tmp <- getTemporaryDirectory
      let dir = tmp </> root
      removePathForcibly dir
      createDirectoryIfMissing True dir
      pure dir
    release dir = removePathForcibly dir

mkPlan :: [String] -> Plan
mkPlan titles = Plan
  { planId = "p#plan"
  , planMode = Stepwise
  , planSteps = [ PlanStep ("p#" ++ show i) (T.pack t) Null StepPending
                | (i, t) <- zip [1 :: Int ..] titles ]
  }

statuses :: Plan -> [StepStatus]
statuses = map planStepStatus . planSteps

planSpec :: Spec
planSpec = do
  describe "FSM — 计划相位" $ do
    it "idle accepts a plan; anything else refuses it" $ do
      transition Idle (SubmitPlanCommand Stepwise) `shouldBe` Planning
      transition Planning (SubmitPlanCommand Stepwise) `shouldBe` Planning
      transition (Completed (Result "x" 1)) (SubmitPlanCommand Stepwise)
        `shouldBe` Completed (Result "x" 1)

    it "approving a step leaves Planning for ExecutingStep" $ do
      transition Planning (ApproveStepCommand "p#1") `shouldBe` ExecutingStep "p#1"

    it "a report brings the session back to the next decision" $ do
      transition (ExecutingStep "p#1") (ReportStepCommand "p#1" True) `shouldBe` Planning

    it "skip keeps planning; reject and abandon stop it" $ do
      transition Planning SkipStepCommand `shouldBe` Planning
      transition Planning RejectStepCommand `shouldBe` Idle
      transition Planning AbandonPlanCommand `shouldBe` Idle
      transition (ExecutingStep "p#1") AbandonPlanCommand `shouldBe` Idle

    it "a conversation step cannot run during a plan (the barrier)" $ do
      transition Planning (StartCommand "s") `shouldBe` Planning
      transition (ExecutingStep "p#1") (StartCommand "s") `shouldBe` ExecutingStep "p#1"

    it "only the pending step can be approved, and only once" $ do
      let plan = mkPlan ["a", "b"]
      pendingStep plan `shouldSatisfy` maybe False ((== "p#1") . planStepId)
      statuses (markApproved plan) `shouldBe` [StepApproved, StepPending]
      -- 'markApproved' approves the *next pending* step; the phase is what
      -- stops a second approval in practice.
      statuses (markApproved (markApproved plan)) `shouldBe` [StepApproved, StepApproved]
      s <- createSession "s"
      _ <- submitPlan s plan
      Just _ <- planMove s MoveApprove
      planMove s MoveApprove `shouldReturn` Nothing

    it "skip/reject move the cursor without executing anything" $ do
      let plan = mkPlan ["a", "b"]
      statuses (markSkipped plan) `shouldBe` [StepSkipped, StepPending]
      statuses (markRejected plan) `shouldBe` [StepRejected, StepPending]

    it "a plan only finishes when nothing is pending and nothing is out" $ do
      let plan = mkPlan ["a"]
          approved = markApproved plan
          done = markReported "p#1" True approved
      planFinished plan `shouldBe` False
      planFinished approved `shouldBe` False   -- still out with the host
      planFinished done `shouldBe` True
      planFinished (markSkipped plan) `shouldBe` True
      planFinished (markReported "p#1" False plan) `shouldBe` True  -- failure is terminal too

  describe "Core.Session — 计划原语" $ do
    it "submitPlan only works from Idle, and only one plan at a time" $ do
      s <- createSession "s"
      submitPlan s (mkPlan ["a"]) `shouldReturn` (Just (mkPlan ["a"]))
      getAgentState s `shouldReturn` Planning
      submitPlan s (mkPlan ["b"]) `shouldReturn` Nothing
      getPlan s `shouldReturn` Just (mkPlan ["a"])

    it "approve → report → approve walks the plan to completion" $ do
      s <- createSession "s"
      _ <- submitPlan s (mkPlan ["a", "b"])
      Just (p1, st1) <- planMove s MoveApprove
      statuses p1 `shouldBe` [StepApproved, StepPending]
      st1 `shouldBe` ExecutingStep "p#1"
      Just (p2, st2) <- planMove s (MoveReport "p#1" True)
      statuses p2 `shouldBe` [StepDone, StepPending]
      st2 `shouldBe` Planning
      Just (p3, st3) <- planMove s MoveApprove
      statuses p3 `shouldBe` [StepDone, StepApproved]
      st3 `shouldBe` ExecutingStep "p#2"
      Just (p4, st4) <- planMove s (MoveReport "p#2" True)
      statuses p4 `shouldBe` [StepDone, StepDone]
      st4 `shouldBe` Idle                       -- finished, back to idle

    it "illegal moves change nothing" $ do
      s <- createSession "s"
      planMove s MoveApprove `shouldReturn` Nothing        -- no plan yet
      _ <- submitPlan s (mkPlan ["a", "b"])
      planMove s (MoveReport "p#1" True) `shouldReturn` Nothing  -- never released
      Just _ <- planMove s MoveApprove
      planMove s MoveApprove `shouldReturn` Nothing         -- already out
      planMove s (MoveReport "p#2" True) `shouldReturn` Nothing -- wrong step
      getAgentState s `shouldReturn` ExecutingStep "p#1"

    it "skip walks past a step without reporting" $ do
      s <- createSession "s"
      _ <- submitPlan s (mkPlan ["a", "b"])
      Just (p1, st1) <- planMove s MoveSkip
      statuses p1 `shouldBe` [StepSkipped, StepPending]
      st1 `shouldBe` Planning

    it "reject halts the plan and keeps the rest as a record" $ do
      s <- createSession "s"
      _ <- submitPlan s (mkPlan ["a", "b"])
      Just (p1, st1) <- planMove s MoveReject
      statuses p1 `shouldBe` [StepRejected, StepPending]
      st1 `shouldBe` Idle
      planMove s MoveApprove `shouldReturn` Nothing   -- halted: nothing to approve

    it "the plan and its phase survive the checkpoint" $ withScratch $ \dir -> do
      s <- createSession "p#1"
      _ <- submitPlan s (mkPlan ["a", "b"])
      _ <- planMove s MoveApprove
      snap <- snapshotSession s
      SS.saveSessionSnapshot dir "p#1" snap
      restored <- SS.loadSessionSnapshot dir "p#1"
      case restored of
        Nothing -> expectationFailure "plan did not round-trip"
        Just snap' -> do
          snapshotAgentState snap' `shouldBe` ExecutingStep "p#1"
          map planStepStatus (planSteps (fromMaybe (mkPlan []) (snapshotPlan snap')))
            `shouldBe` [StepApproved, StepPending]
          s' <- restoreSession snap' []
          getPlan s' `shouldReturn` snapshotPlan snap'

  describe "API — 计划的线上契约（真实 warp）" $ do
    let withApp :: IO Application -> (Manager -> String -> IO a) -> IO a
        withApp app act = testWithApplication app $ \port -> do
          mgr <- newManager defaultManagerSettings
          act mgr ("http://127.0.0.1:" ++ show port)

        call :: Manager -> String -> String -> Value -> IO (Int, String)
        call mgr method url body = do
          req0 <- parseRequest (method ++ " " ++ url)
          let r = req0 { requestBody    = RequestBodyLBS (encode body)
                       , requestHeaders = [("Content-Type", "application/json")] }
          res <- httpLbs r mgr
          pure (statusCode (responseStatus res), BLC.unpack (responseBody res))

        start = object ["sessionId" .= ("plan-1" :: T.Text)]
        planBody = object
          [ "mode" .= ("stepwise" :: T.Text)
          , "steps" .=
              [ object ["id" .= ("s1" :: T.Text), "title" .= ("create branch" :: T.Text)]
              , object ["id" .= ("s2" :: T.Text), "title" .= ("edit files" :: T.Text)]
              , object ["id" .= ("s3" :: T.Text), "title" .= ("run tests" :: T.Text)]
              ]
          ]
        action a = object ["action" .= (a :: T.Text)]
        report sid ok = object [ "stepId" .= (sid :: T.Text), "ok" .= ok ]

    it "submit → approve → report walks step by step, and steps are blocked meanwhile" $
      withScratch $ \dir -> withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (_, _) <- call mgr "POST" (base ++ "/session/start") start
        (c0, body0) <- call mgr "POST" (base ++ "/session/plan-1/plan") planBody
        c0 `shouldBe` 200
        body0 `shouldSatisfy` ("\"status\":\"planning\"" `isInfixOf`)
        body0 `shouldSatisfy` ("\"pending\":{\"id\":\"s1\"" `isInfixOf`)

        -- a conversation step may not interleave with a plan
        (cs, bodyS) <- call mgr "POST" (base ++ "/agent/step")
          (object ["sessionId" .= ("plan-1" :: T.Text), "message" .= ("hi" :: T.Text)])
        cs `shouldBe` 409
        bodyS `shouldSatisfy` ("plan.active" `isInfixOf`)

        (c1, body1) <- call mgr "POST" (base ++ "/session/plan-1/decision") (action "approve")
        c1 `shouldBe` 200
        body1 `shouldSatisfy` ("\"status\":\"step_approved\"" `isInfixOf`)
        body1 `shouldSatisfy` ("\"state\":\"executing_step\"" `isInfixOf`)

        -- reporting a step that is not out is refused
        (cBad, _) <- call mgr "POST" (base ++ "/session/plan-1/step-result") (report "s3" True)
        cBad `shouldBe` 409

        (c2, body2) <- call mgr "POST" (base ++ "/session/plan-1/step-result") (report "s1" True)
        c2 `shouldBe` 200
        body2 `shouldSatisfy` ("\"status\":\"step_done\"" `isInfixOf`)
        body2 `shouldSatisfy` ("\"pending\":{\"id\":\"s2\"" `isInfixOf`)

    it "skip advances without executing; reject halts and leaves the rest pending" $
      withScratch $ \dir -> withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (_, _) <- call mgr "POST" (base ++ "/session/start") start
        (_, _) <- call mgr "POST" (base ++ "/session/plan-1/plan") planBody

        (c1, body1) <- call mgr "POST" (base ++ "/session/plan-1/decision") (action "skip")
        c1 `shouldBe` 200
        body1 `shouldSatisfy` ("\"status\":\"step_skipped\"" `isInfixOf`)
        body1 `shouldSatisfy` ("\"pending\":{\"id\":\"s2\"" `isInfixOf`)

        (c2, body2) <- call mgr "POST" (base ++ "/session/plan-1/decision") (action "reject")
        c2 `shouldBe` 200
        body2 `shouldSatisfy` ("\"status\":\"rejected\"" `isInfixOf`)
        body2 `shouldSatisfy` ("\"state\":\"idle\"" `isInfixOf`)

        -- the halted plan is still readable, with the decision recorded
        (c3, body3) <- call mgr "GET" (base ++ "/session/plan-1/plan") (object [])
        c3 `shouldBe` 200
        body3 `shouldSatisfy` ("\"status\":\"skipped\"" `isInfixOf`)
        body3 `shouldSatisfy` ("\"status\":\"rejected\"" `isInfixOf`)

        -- and a plain step runs again
        (c4, _) <- call mgr "POST" (base ++ "/agent/step")
          (object ["sessionId" .= ("plan-1" :: T.Text), "message" .= ("carry on" :: T.Text)])
        c4 `shouldBe` 200

    it "the last step finishes the plan and releases the barrier" $
      withScratch $ \dir -> withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (_, _) <- call mgr "POST" (base ++ "/session/start") start
        (_, _) <- call mgr "POST" (base ++ "/session/plan-1/plan")
          (object ["steps" .= [object ["id" .= ("only" :: T.Text)]]])
        (_, _) <- call mgr "POST" (base ++ "/session/plan-1/decision") (action "approve")
        (c1, body1) <- call mgr "POST" (base ++ "/session/plan-1/step-result") (report "only" True)
        c1 `shouldBe` 200
        body1 `shouldSatisfy` ("\"state\":\"idle\"" `isInfixOf`)
        body1 `shouldSatisfy` ("\"pending\":null" `isInfixOf`)
        -- and a conversation step works again
        (c2, _) <- call mgr "POST" (base ++ "/agent/step")
          (object ["sessionId" .= ("plan-1" :: T.Text), "message" .= ("after" :: T.Text)])
        c2 `shouldBe` 200

    it "a second plan while one is active is refused" $ withScratch $ \dir ->
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (_, _) <- call mgr "POST" (base ++ "/session/start") start
        (c1, _) <- call mgr "POST" (base ++ "/session/plan-1/plan") planBody
        c1 `shouldBe` 200
        (c2, body2) <- call mgr "POST" (base ++ "/session/plan-1/plan") planBody
        c2 `shouldBe` 409
        body2 `shouldSatisfy` ("plan.active" `isInfixOf`)

    it "rejects an empty plan, and auto mode is explicitly unsupported" $ withScratch $ \dir ->
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (_, _) <- call mgr "POST" (base ++ "/session/start") start
        (c1, body1) <- call mgr "POST" (base ++ "/session/plan-1/plan") (object ["steps" .= ([] :: [Value])])
        c1 `shouldBe` 400
        body1 `shouldSatisfy` ("plan.empty" `isInfixOf`)
        (c2, body2) <- call mgr "POST" (base ++ "/session/plan-1/plan")
          (object ["mode" .= ("auto" :: T.Text), "steps" .= [object ["id" .= ("x" :: T.Text)]]])
        c2 `shouldBe` 400
        body2 `shouldSatisfy` ("plan.mode_unsupported" `isInfixOf`)

    it "an approved step survives a restart and can still be reported" $ withScratch $ \dir -> do
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (_, _) <- call mgr "POST" (base ++ "/session/start") start
        (_, _) <- call mgr "POST" (base ++ "/session/plan-1/plan") planBody
        (c1, _) <- call mgr "POST" (base ++ "/session/plan-1/decision") (action "approve")
        c1 `shouldBe` 200

      -- fresh instance: no /session/start, no re-submitted plan
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (cS, bodyS) <- call mgr "POST" (base ++ "/agent/step")
          (object ["sessionId" .= ("plan-1" :: T.Text), "message" .= ("hi" :: T.Text)])
        cS `shouldBe` 409
        bodyS `shouldSatisfy` ("plan.active" `isInfixOf`)
        -- the step that was out is still out, with its id
        (c1, body1) <- call mgr "POST" (base ++ "/session/plan-1/step-result") (report "s1" True)
        c1 `shouldBe` 200
        body1 `shouldSatisfy` ("\"pending\":{\"id\":\"s2\"" `isInfixOf`)
