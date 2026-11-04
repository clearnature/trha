{-# LANGUAGE OverloadedStrings #-}

-- | 计划与审批端点：单步计划、多步计划（提交/拉取/决策/上报）、
-- 最终裁决（approve/deny/denyWithReason/decide），以及 agent 状态读写。
--
-- 从 "Bridge.Scheduler" 拆出（约定见 "Bridge.Scheduler.Core"）。
module Bridge.Scheduler.Plan
  ( planStep, submitPlan, fetchPlan, decideStep, reportStep
  , approvePlan, denyPlan, denyPlanWithReason, decidePlan
  , getAgentState, updateAgentState
  ) where

import Bridge.Scheduler.Core (SchedulerBridge(..))
import Core.Types
import Core.HTTP
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseMaybe, (.:), (.:?), (.!=))
import Data.Text (Text)
import qualified Data.Text as T

planStep :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError PlanSubmit)
planStep bridge sessionId message = do
  result <- httpPost (bridgeHTTP bridge) "/api/agent/step"
    (object [ "sessionId" .= sessionId, "message" .= message, "requireApproval" .= True ])
    :: IO (Either CLIError Value)
  return $ case result of
    Right (Object r) ->
      case parseMaybe (.: "status") r :: Maybe Text of
        Just "awaiting_approval" ->
          case parseMaybe (.: "pending") r :: Maybe Value of
            Just (Object po) -> case parseMaybe (.: "message") po :: Maybe Text of
              Just msg -> Right (PlanAwaiting msg)
              Nothing  -> Left $ ValidationError "Missing pending.message"
            _ -> Left $ ValidationError "Missing pending"
        Just other -> Left $ ValidationError $ "Unexpected plan status: " <> other
        Nothing -> Left $ ValidationError "Missing status"
    Right _ -> Left $ ValidationError "Invalid plan response"
    Left err -> Left err

--------------------------------------------------------------------------------
-- Multi-step plans (kernel-owned)
--
-- The kernel holds the steps, the phase and the barrier; these calls only
-- relay. Every response carries the whole plan back, so the shell can render
-- the card from the answer instead of keeping its own copy in sync.
--------------------------------------------------------------------------------

-- | Submit a stepwise plan. Steps are titles; the kernel numbers them.

submitPlan :: SchedulerBridge -> SessionId -> [Text] -> IO (Either CLIError PlanView)
submitPlan bridge sessionId stepTitles = do
  let body = object
        [ "mode"  .= ("stepwise" :: Text)
        , "steps" .= [ object [ "title" .= t ] | t <- stepTitles ]
        ]
  result <- httpPost (bridgeHTTP bridge)
    ("/api/session/" ++ sessionId ++ "/plan") body :: IO (Either CLIError Value)
  pure (result >>= planViewOr)

-- | Read the current plan (also works after a restart: the kernel persists it).

fetchPlan :: SchedulerBridge -> SessionId -> IO (Either CLIError PlanView)
fetchPlan bridge sessionId = do
  result <- httpGet (bridgeHTTP bridge) ("/api/session/" ++ sessionId ++ "/plan")
  pure (result >>= planViewOr)

-- | One decision on the pending step: approve, skip, reject or abandon.

decideStep :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError PlanView)
decideStep bridge sessionId action = do
  result <- httpPost (bridgeHTTP bridge)
    ("/api/session/" ++ sessionId ++ "/decision") (object ["action" .= action])
    :: IO (Either CLIError Value)
  pure (result >>= planViewOr)

-- | Report how an approved step went. The kernel will not guess: until this
-- arrives the step stays "approved" and the plan stays in its executing phase.

reportStep :: SchedulerBridge -> SessionId -> Text -> Bool -> IO (Either CLIError PlanView)
reportStep bridge sessionId stepId ok = do
  result <- httpPost (bridgeHTTP bridge)
    ("/api/session/" ++ sessionId ++ "/step-result")
    (object ["stepId" .= stepId, "ok" .= ok]) :: IO (Either CLIError Value)
  pure (result >>= planViewOr)

planViewOr :: Value -> Either CLIError PlanView
planViewOr v = case parsePlanView v of
  Just pv -> Right pv
  Nothing -> Left $ ValidationError "Invalid plan response"

-- | Approve the pending plan; returns the agent reply.

approvePlan :: SchedulerBridge -> SessionId -> IO (Either CLIError PlanVerdict)
approvePlan bridge sessionId = decidePlan bridge sessionId True

-- | Deny the pending plan.

denyPlan :: SchedulerBridge -> SessionId -> IO (Either CLIError PlanVerdict)
denyPlan bridge sessionId = decidePlan bridge sessionId False

-- | Deny the pending plan with a reason (forwarded to the kernel, where it
-- can be shown to the model as the rejection cause).

denyPlanWithReason :: SchedulerBridge -> SessionId -> Text -> IO (Either CLIError PlanVerdict)
denyPlanWithReason bridge sessionId reason = do
  result <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sessionId ++ "/decision")
    (object ["action" .= ("reject" :: Text), "reason" .= reason])
    :: IO (Either CLIError Value)
  return $ case result of
    Right (Object r) ->
      case parseMaybe (.: "status") r :: Maybe Text of
        Just "rejected" -> Right PlanDenied
        Just other      -> Left $ ValidationError $ "Unexpected decision status: " <> other
        Nothing         -> Left $ ValidationError "Missing status"
    Right _ -> Left $ ValidationError "Unexpected decision payload"
    Left err -> Left err

-- | Shared implementation of POST /api/session/:id/decision.

decidePlan :: SchedulerBridge -> SessionId -> Bool -> IO (Either CLIError PlanVerdict)
decidePlan bridge sessionId approve = do
  result <- httpPost (bridgeHTTP bridge) ("/api/session/" ++ sessionId ++ "/decision")
    (object ["approve" .= approve])
    :: IO (Either CLIError Value)
  return $ case result of
    Right (Object r) ->
      case parseMaybe (.: "status") r :: Maybe Text of
        Just "approved" ->
          case parseMaybe (.: "reply") r :: Maybe Text of
            Just reply -> Right (PlanApproved reply)
            Nothing    -> Left $ ValidationError "Missing reply"
        Just "denied"  -> Right PlanDenied
        Just other     -> Left $ ValidationError $ "Unexpected decision status: " <> other
        Nothing        -> Left $ ValidationError "Missing status"
    Right _ -> Left $ ValidationError "Invalid decision response"
    Left err -> Left err

getAgentState :: SchedulerBridge -> AgentId -> IO (Either CLIError AgentState)
getAgentState _ _ =
  return $ Left $ UnknownCLIError "getAgentState: not wired to orchestration API"

updateAgentState :: SchedulerBridge -> AgentId -> AgentState -> IO (Either CLIError ())
updateAgentState _ _ _ =
  return $ Left $ UnknownCLIError "updateAgentState: not wired to orchestration API"

--------------------------------------------------------------------------------
-- Model Operations
--------------------------------------------------------------------------------
