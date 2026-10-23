-- | The kernel's approval gate: a command parks at 'AwaitingApproval' until
-- the host decides, and nothing may step past it.
--
-- Two levels again:
--
--   * FSM/Manager level pins the legal moves (and that the *illegal* ones are
--     inert) — a second request, a second decision, a step while parked;
--   * HTTP level pins the wire contract the scheduler delegates to, including
--     that a parked command survives a restart.
{-# LANGUAGE OverloadedStrings #-}

module ApprovalSpec (approvalSpec) where

import Control.Exception (bracket)
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.List (isInfixOf)
import qualified Data.Text as T
import Network.HTTP.Client
import Network.HTTP.Types (statusCode)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import System.Directory
import System.FilePath ((</>))
import Test.Hspec

import API.Server (mkStubApp)
import Core.Agent.StateMachine (AgentCommand (..), transition)
import Core.Agent.Types (AgentState (..), ApprovalRequest (..), Result (..))
import Core.Session.Manager
import Core.Session.Types
import qualified Infrastructure.Storage.SessionStore as SS

withScratch :: (FilePath -> IO a) -> IO a
withScratch act = bracket acquire release act
  where
    root = "trha-approval-spec"
    acquire = do
      tmp <- getTemporaryDirectory
      let dir = tmp </> root
      removePathForcibly dir
      createDirectoryIfMissing True dir
      pure dir
    release dir = removePathForcibly dir

req :: String -> ApprovalRequest
req i = ApprovalRequest
  { approvalId      = i
  , approvalAction  = "step"
  , approvalSummary = "run: rm -rf build"
  , approvalPayload = object ["message" .= ("rm -rf build" :: T.Text)]
  }

approvalSpec :: Spec
approvalSpec = do
  describe "FSM — 审批是闸门，不是执行器" $ do
    it "parks from Idle and releases to Idle on approval" $ do
      transition Idle (RequestApprovalCommand (req "a#1"))
        `shouldBe` AwaitingApproval (req "a#1")
      transition (AwaitingApproval (req "a#1")) ApproveCommand `shouldBe` Idle

    it "parks mid-step too (a tool asking permission while a step runs)" $ do
      transition (Processing "step-1") (RequestApprovalCommand (req "a#2"))
        `shouldBe` AwaitingApproval (req "a#2")

    it "releases to Idle on rejection — a refusal is not a fault" $ do
      transition (AwaitingApproval (req "a#1")) RejectCommand `shouldBe` Idle

    it "blocks every other command while parked (the barrier)" $ do
      let parked = AwaitingApproval (req "a#1")
      transition parked (StartCommand "s") `shouldBe` parked
      transition parked (ToolCallCommand "c" "tool") `shouldBe` parked
      transition parked (ToolResultCommand "r") `shouldBe` parked
      transition parked (CompleteCommand (Result "done" 7)) `shouldBe` parked
      -- and the park cannot be overwritten by a new request instead of decided
      transition parked (RequestApprovalCommand (req "a#2")) `shouldBe` parked

    it "ignores a decision when nothing is parked" $ do
      transition Idle ApproveCommand `shouldBe` Idle
      transition (Completed (Result "done" 7)) RejectCommand
        `shouldBe` Completed (Result "done" 7)

  describe "Core.Session — 闸门原语" $ do
    it "requestApproval parks, second request is refused" $ do
      s <- createSession "s"
      requestApproval s (req "s#1") `shouldReturn` Just (req "s#1")
      pendingApproval s `shouldReturn` Just (req "s#1")
      requestApproval s (req "s#2") `shouldReturn` Nothing
      pendingApproval s `shouldReturn` Just (req "s#1")

    it "decideApproval releases once; a second decision loses the race" $ do
      s <- createSession "s"
      _ <- requestApproval s (req "s#1")
      decideApproval s True `shouldReturn` Just Idle
      pendingApproval s `shouldReturn` Nothing
      decideApproval s False `shouldReturn` Nothing

    it "decideApproval on a free session decides nothing" $ do
      s <- createSession "s"
      decideApproval s True `shouldReturn` Nothing
      getAgentState s `shouldReturn` Idle

    it "a parked request survives the checkpoint round-trip" $ withScratch $ \dir -> do
      s <- createSession "s#park"
      _ <- requestApproval s (req "s#1")
      snap <- snapshotSession s
      SS.saveSessionSnapshot dir "s#park" snap
      loaded <- SS.loadSessionSnapshot dir "s#park"
      case loaded of
        Nothing -> expectationFailure "approval state did not round-trip"
        Just snap' -> do
          snapshotAgentState snap' `shouldBe` AwaitingApproval (req "s#1")
          restored <- restoreSession snap' []
          pendingApproval restored `shouldReturn` Just (req "s#1")

  describe "API — 审批闸门的线上契约（真实 warp）" $ do
    let withApp :: IO Application -> (Manager -> String -> IO a) -> IO a
        withApp app act = testWithApplication app $ \port -> do
          mgr <- newManager defaultManagerSettings
          act mgr ("http://127.0.0.1:" ++ show port)

        call :: Manager -> String -> String -> Value -> IO (Int, String)
        call mgr method url body = do
          -- parseRequest already carries the method; only body/headers are set
          req0 <- parseRequest (method ++ " " ++ url)
          let r = req0 { requestBody    = RequestBodyLBS (encode body)
                       , requestHeaders = [("Content-Type", "application/json")]
                       }
          res <- httpLbs r mgr
          pure (statusCode (responseStatus res), BLC.unpack (responseBody res))

        start = object ["sessionId" .= ("gate-1" :: T.Text)]
        stepReq = object [ "sessionId" .= ("gate-1" :: T.Text)
                         , "message"   .= ("rm -rf build" :: T.Text) ]
        approveReq = object ["approve" .= True]
        rejectReq = object ["approve" .= False]

    it "parks, blocks the step, releases on approval" $ withScratch $ \dir ->
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (s0, _) <- call mgr "POST" (base ++ "/session/start") start
        s0 `shouldBe` 200
        (a0, bodyA) <- call mgr "POST" (base ++ "/session/gate-1/approval") stepReq
        a0 `shouldBe` 200
        bodyA `shouldSatisfy` ("\"status\":\"awaiting_approval\"" `isInfixOf`)
        bodyA `shouldSatisfy` ("\"action\":\"step\"" `isInfixOf`)

        -- the barrier: a step may not slip past the pending decision
        (s1, bodyS) <- call mgr "POST" (base ++ "/agent/step") stepReq
        s1 `shouldBe` 409
        bodyS `shouldSatisfy` ("approval.pending" `isInfixOf`)

        (d1, bodyD) <- call mgr "POST" (base ++ "/session/gate-1/decision") approveReq
        d1 `shouldBe` 200
        bodyD `shouldSatisfy` ("\"status\":\"approved\"" `isInfixOf`)
        bodyD `shouldSatisfy` ("\"state\":\"idle\"" `isInfixOf`)

        -- released: the host re-issues the step and it runs
        (s2, _) <- call mgr "POST" (base ++ "/agent/step") stepReq
        s2 `shouldBe` 200

    it "rejection releases the gate without erroring the session" $ withScratch $ \dir ->
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (_, _) <- call mgr "POST" (base ++ "/session/start") start
        (a0, _) <- call mgr "POST" (base ++ "/session/gate-1/approval") stepReq
        a0 `shouldBe` 200
        (d0, bodyD) <- call mgr "POST" (base ++ "/session/gate-1/decision") rejectReq
        d0 `shouldBe` 200
        bodyD `shouldSatisfy` ("\"status\":\"denied\"" `isInfixOf`)
        bodyD `shouldSatisfy` ("\"state\":\"idle\"" `isInfixOf`)
        -- the log keeps the refusal, and the session still works
        (_, bodyE) <- call mgr "GET" (base ++ "/session/gate-1/events") (object [])
        bodyE `shouldSatisfy` ("approval_requested" `isInfixOf`)
        bodyE `shouldSatisfy` ("\"approve\":false" `isInfixOf`)
        (s1, _) <- call mgr "POST" (base ++ "/agent/step") stepReq
        s1 `shouldBe` 200

    it "a second decision finds nothing parked (double click is harmless)" $ withScratch $ \dir ->
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (_, _) <- call mgr "POST" (base ++ "/session/start") start
        (d0, _) <- call mgr "POST" (base ++ "/session/gate-1/decision") approveReq
        d0 `shouldBe` 400
        (_, body) <- call mgr "POST" (base ++ "/session/gate-1/decision") approveReq
        body `shouldSatisfy` ("approval.none" `isInfixOf`)

    it "a second request while parked is refused (409)" $ withScratch $ \dir ->
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (_, _) <- call mgr "POST" (base ++ "/session/start") start
        (a0, _) <- call mgr "POST" (base ++ "/session/gate-1/approval") stepReq
        a0 `shouldBe` 200
        (a1, _) <- call mgr "POST" (base ++ "/session/gate-1/approval") stepReq
        a1 `shouldBe` 409

    it "unknown session is 404 for both endpoints" $ withScratch $ \dir ->
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (c1, _) <- call mgr "POST" (base ++ "/session/nobody/approval") stepReq
        c1 `shouldBe` 404
        (c2, _) <- call mgr "POST" (base ++ "/session/nobody/decision") approveReq
        c2 `shouldBe` 404

    it "a parked request survives a restart and can still be decided" $ withScratch $ \dir -> do
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (_, _) <- call mgr "POST" (base ++ "/session/start") start
        (a0, _) <- call mgr "POST" (base ++ "/session/gate-1/approval") stepReq
        a0 `shouldBe` 200

      -- fresh instance, same state directory, no /session/start
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (c, bodyS) <- call mgr "POST" (base ++ "/agent/step") stepReq
        c `shouldBe` 409                                -- restored, still parked
        bodyS `shouldSatisfy` ("approval.pending" `isInfixOf`)
        (d0, bodyD) <- call mgr "POST" (base ++ "/session/gate-1/decision") approveReq
        d0 `shouldBe` 200                              -- the pending request came back
        bodyD `shouldSatisfy` ("\"status\":\"approved\"" `isInfixOf`)
        -- the request id is the one issued before the restart
        bodyD `shouldSatisfy` ("gate-1#1" `isInfixOf`)
