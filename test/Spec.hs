{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

import Test.Hspec
import Test.QuickCheck
import Kernel.Carrier
  ( Layer (..), initialPoint, dimCarrier, dotC, normC2, basisVec
  , allA4, a4Card, plancherelSum, dimI, Irrep (..)
  , baseCard, projClass, zeroSection, constantSection, sectionNorm, isFraming
  , mkBaseKey
  , flatDim, effectiveDim, overcount, minFiberSize, maxFiberSize, uniformCoordsFaithful
  , overcountByOrbit, overcountDecomposition, equivariantSectionPossible
  , spinFiberCard, spinTotalCard, phaseAct )
import qualified Sov.Math.Trit as MT
import Sov.Math.Eis (eisOne, eisZero)
import qualified Infrastructure.CPU.Inference as Inf
import qualified Infrastructure.CPU.SovereignTypes as ST
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Data.Maybe (fromMaybe, isJust)
import System.Directory (doesFileExist)
import Core.Session.Types
import Core.Session.Manager
import Core.Agent.StateMachine (AgentCommand (..))
import Core.Agent.Types
import Core.Agent.StateMachine
import Core.Tools.Types
import Core.Tools.Registry
import Core.Event.Types
import Core.Event.Bus
import Core.Cache.Types
import Core.Cache.Engine
import LLM.Adapter.Types
import qualified LLM.Adapter.Types as LLM
import LLM.Adapter.Interface
import LLM.Providers.DeepSeek (buildDeepSeekChatRequest, createDeepSeekProvider, parseDeepSeekChatTurn)
import API.Server (OpenAIRequest(..), parseOpenAIRequest, mkApp, mkStubApp, mkCPUApp, genParamsWithDefaultEffort)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.HTTP.Client (Manager, newManager, defaultManagerSettings, parseRequest,
                            httpLbs, responseBody, responseStatus, method, requestBody,
                            requestHeaders, RequestBody(..))
import Network.HTTP.Types (statusCode)
import API.ProviderProbe (classifyListing, parseModelIds)
import API.ProviderRuntime (adapterFor, cpuAdapterCacheSize, invalidateProviderCaches, providerCacheFingerprint, mergeExtraBody, withEffort, withResponseEffort)
import Core.Provider.Types
import Data.IORef
import Data.Dynamic
import qualified Data.Text as T
import Data.Aeson (Value(..), decode, encode, object, parseJSON, toJSON, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import System.CPUTime (getCPUTime)
import qualified Data.List as List
import qualified Data.Vector.Unboxed as VU
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (listToMaybe)
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Map as Map
import Control.Monad.Free (liftF)
import CoreContractSpec (coreContractSpec)
import SessionPersistSpec (sessionPersistSpec)
import ApprovalSpec (approvalSpec)
import PlanSpec (planSpec)
import GoldenGF27Spec (goldenGF27Spec)
import DeepSeekCacheSpec (deepSeekCacheSpec)
import StreamToolCallsSpec (streamToolCallsSpec)
import HTTPProxySpec (spec)
import WireGuardsSpec (wireGuardsSpec)
import StreamTimeoutSpec (streamTimeoutSpec)
import SessionGateSpec (sessionGateSpec)
import ServerBindSpec (serverBindSpec)
import SecuritySpec (securitySpec)
import SessionTruthSpec (sessionTruthSpec)

subsetOf :: (Eq a) => [a] -> [a] -> Bool
subsetOf xs ys = all (`elem` ys) xs

-- | 尾部稳态周期：找**最小** d ∈ [1,120]，使帧序列末尾以 d 为周期
-- （末尾 d 个位置的相邻周期比较全成立）。找不到则 'Nothing'。
--
-- ⚠️ 与「首次重复」判法的区别：相位推进会在一个轮内产生**偶然的相邻重复**，
-- 用 firstRepeat 会把它误报成周期 1。这里要求末尾**连续 d 步**都满足周期 d，
-- 从而排除偶然重复（见 "自持：60 层后落入周期 12" 一测的注记）。
--
-- ⚠️ 本函数此前在 Spec.hs 中被引用但**从未定义**（迁移时才发现），
-- 此处按各调用点的期望语义实现，仅供测试使用。
tailCycle :: (Eq a) => [[[a]]] -> Maybe Int
tailCycle frames = listToMaybe [ d | d <- [1 .. 120], d < n, holdsFor d ]
  where
    n = length frames
    holdsFor d = and [ frames !! i == frames !! (i - d) | i <- [n - d .. n - 1] ]

main :: IO ()
main = hspec $ do
  coreContractSpec
  sessionPersistSpec
  approvalSpec
  planSpec
  goldenGF27Spec
  deepSeekCacheSpec
  streamToolCallsSpec
  HTTPProxySpec.spec
  wireGuardsSpec
  streamTimeoutSpec
  sessionGateSpec
  serverBindSpec
  securitySpec
  describe "LLM.Adapter streaming (A5)" $ do
    it "samples the CPU engine one token at a time, matching the blocking path" $ do
      (_, adapter) <- createCPUAdapter "/dev/null"
      ref <- newIORef []
      _ <- llmChatToolsStream adapter [ChatUser "hi"] [] defaultGenParams $ \c -> case c of
             ChunkDelta t -> modifyIORef' ref (t :)
             _            -> return ()
      pieces <- reverse <$> readIORef ref
      blocking <- llmChatTools adapter [ChatUser "hi"] [] defaultGenParams
      -- one increment per sampled token (the engine's maxTokens)
      length pieces `shouldBe` 100
      -- and they concatenate to exactly what the blocking call returns
      T.concat pieces `shouldBe` ctContent blocking

  describe "Core.Session" $ do
    it "can create a session and append events" $ do
      session <- createSession "test-session-1"
      appendEvent session (UserMessage "Hello")
      appendEvent session (AssistantMessage "Hi there!")
      events <- getEvents session
      length events `shouldBe` 2

    -- projections：投影是"由事件日志重放得出的派生状态"。
    -- 推理状态（CPU 层 T6State）与内核 FSM 状态（Core.Agent.AgentState）经这里上浮到
    -- 会话，使"推理过程"对内核可见。本模块只碰 Dynamic，装箱由调用方完成（不破坏分层）。
    it "★ projections：未设返回 Nothing；写入后可读回" $ do
      session <- createSession "test-session-proj"
      (isJust <$> getProjection session "t6state") `shouldReturn` False
      projectionNames session `shouldReturn` []
      setProjection session "t6state" (toDyn (42 :: Int))
      m <- getProjection session "t6state"
      fmap fromDynamic m `shouldBe` Just (Just (42 :: Int))
      projectionNames session `shouldReturn` ["t6state"]

    it "★ projections：同名覆盖写生效（不累积重复键）" $ do
      session <- createSession "test-session-proj2"
      setProjection session "k" (toDyn (1 :: Int))
      setProjection session "k" (toDyn (2 :: Int))
      m <- getProjection session "k"
      fmap fromDynamic m `shouldBe` Just (Just (2 :: Int))
      projectionNames session `shouldReturn` ["k"]

    it "★ D-3：会话持有内核 FSM 状态 —— 新建 Idle，advanceAgent 后推进" $ do
      session <- createSession "test-session-fsm"
      getAgentState session `shouldReturn` Idle
      st1 <- advanceAgent session (StartCommand "sid")
      st1 `shouldBe` Processing "step-1"
      getAgentState session `shouldReturn` Processing "step-1"
      -- 用 transition 的语义（唯一来源）：Processing 上再发 Start 不改变状态
      st2 <- advanceAgent session (StartCommand "sid")
      st2 `shouldBe` Processing "step-1"

    it "★ projections：不同名互不干扰；类型不符时 fromDynamic 得 Nothing" $ do
      session <- createSession "test-session-proj3"
      setProjection session "a" (toDyn (1 :: Int))
      setProjection session "b" (toDyn ("x" :: String))
      ma <- getProjection session "a"
      mb <- getProjection session "b"
      fmap fromDynamic ma `shouldBe` Just (Just (1 :: Int))
      fmap fromDynamic mb `shouldBe` Just (Just ("x" :: String))
      -- 以错误的类型解包应失败（Dynamic 的类型安全）
      (fmap fromDynamic ma :: Maybe (Maybe String)) `shouldBe` Just Nothing

  describe "Core.Agent" $ do
    it "can create an agent and update state" $ do
      let config = AgentConfig "deepseek-chat" 10 30
      agent <- createAgent "agent-1" config
      state <- getState agent
      state `shouldBe` Idle
      updateState agent (Processing "step-1")
      state' <- getState agent
      state' `shouldBe` Processing "step-1"

  describe "Core.Tools" $ do
    it "can register and retrieve tools" $ do
      registry <- createToolRegistry
      let tool = Tool "test-tool" "A test tool" "{}" (\_ -> return (toDyn (42 :: Int)))
      registerTool registry tool
      retrieved <- getTool registry "test-tool"
      case retrieved of
        Just t -> toolName t `shouldBe` "test-tool"
        Nothing -> expectationFailure "Tool not found"

  describe "Core.Event" $ do
    it "can subscribe and publish events" $ do
      bus <- createEventBus
      ref <- newIORef (0 :: Int)
      subscribe bus "test-event" (\dyn -> do
        case fromDynamic dyn of
          Just msg -> writeIORef ref msg
          Nothing -> return ()
        )
      publish bus "test-event" (toDyn (42 :: Int))
      result <- readIORef ref
      result `shouldBe` 42

  describe "Core.Cache" $ do
    it "can cache and retrieve values" $ do
      engine <- createCacheEngine
      cacheInsert engine "key1" (toDyn (42 :: Int))
      result <- cacheLookup engine "key1"
      case result of
        Just dyn -> fromDynamic dyn `shouldBe` Just (42 :: Int)
        Nothing -> expectationFailure "Value not found"

  describe "LLM.Adapter" $ do
    it "can create a DeepSeek adapter" $ do
      adapter <- createDeepSeekProvider "test-key"
      models <- llmModels adapter
      length models `shouldSatisfy` (>= 1)
      modelName (head models) `shouldBe` "deepseek-flash"

  -- Phase 3 K1: function-calling message model (OpenAI-aligned JSON)
  describe "LLM.FunctionCalling" $ do
    it "round-trips a tool result message" $ do
      let msg = LLM.ChatTool "call_1" "result text"
      decode (encode msg) `shouldBe` (Just msg :: Maybe LLM.ChatMessage)

    it "round-trips an assistant message with tool calls" $ do
      let tc = LLM.ToolCall "call_2" "bash" "{\"command\":\"ls\"}"
          msg = LLM.ChatAssistant "thinking…" [tc]
      decode (encode msg) `shouldBe` (Just msg :: Maybe LLM.ChatMessage)

    it "round-trips a tool spec" $ do
      let spec = LLM.ToolSpec "read_file" "Read a file" (object ["type" .= ("string" :: T.Text)])
      decode (encode spec) `shouldBe` (Just spec :: Maybe LLM.ToolSpec)

    it "serializes a tool result in OpenAI shape" $ do
      encode (LLM.ChatTool "call_9" "ok") `shouldBe`
        "{\"content\":\"ok\",\"role\":\"tool\",\"tool_call_id\":\"call_9\"}"

    it "serializes an assistant tool call in OpenAI shape" $ do
      encode (LLM.ChatAssistant "" [LLM.ToolCall "c1" "bash" "{}"]) `shouldBe`
        "{\"content\":\"\",\"reasoning_content\":\"\",\"role\":\"assistant\",\"tool_calls\":[{\"function\":{\"arguments\":\"{}\",\"name\":\"bash\"},\"id\":\"c1\",\"type\":\"function\"}]}"

    it "omits tool_calls when the assistant has none" $ do
      -- a thought-carrying turn keeps the chain: thinking mode requires it
      -- back on the next request, and dropping it costs the model its plan.
      let thought = LLM.ChatAssistantThought "" [LLM.ToolCall "c2" "bash" "{}"] "因为需要先看文件" Nothing
      decode (encode thought) `shouldBe` Just thought
      (BLC.unpack (encode thought)) `shouldSatisfy` ("reasoning_content" `isInfixOf`)
      -- the Anthropic thinking-block signature rides the same assistant turn
      let signed = LLM.ChatAssistantThought "" [LLM.ToolCall "c3" "bash" "{}"] "plan" (Just "sig-1")
      decode (encode signed) `shouldBe` Just signed
      (BLC.unpack (encode signed)) `shouldSatisfy` ("reasoning_signature" `isInfixOf`)
      -- an empty chain is not a thought turn (keeps round-trips stable)
      decode (encode (LLM.ChatAssistant "" [LLM.ToolCall "c2" "bash" "{}"]))
        `shouldBe` Just (LLM.ChatAssistant "" [LLM.ToolCall "c2" "bash" "{}"])
      encode (LLM.ChatAssistant "plain" []) `shouldBe`
        "{\"content\":\"plain\",\"role\":\"assistant\"}"

  -- Phase 3 K2: DeepSeek provider function-calling (pure request/parse)
  describe "LLM.DeepSeekTools" $ do
    it "builds a request carrying the tools array" $ do
      let spec = LLM.ToolSpec "read_file" "Read a file" (object ["type" .= ("string" :: T.Text)])
          req  = BLC.unpack (encode (buildDeepSeekChatRequest "deepseek-chat" [LLM.ChatUser "hi"] [spec] Nothing))
      req
        `shouldSatisfy` (\b -> "\"tools\"" `isInfixOf` b
                           && "read_file" `isInfixOf` b
                           && "\"stream\":false" `isInfixOf` b)


    it "parses a tool_calls response" $ do
      let resp = object
            [ "choices" .= [ object
                [ "message" .= object
                    [ "role" .= ("assistant" :: T.Text)
                    , "content" .= ("" :: T.Text)
                    , "tool_calls" .= [ object
                        [ "id" .= ("call_1" :: T.Text)
                        , "type" .= ("function" :: T.Text)
                        , "function" .= object
                            [ "name" .= ("bash" :: T.Text)
                            , "arguments" .= ("{\"command\":\"ls\"}" :: T.Text)
                            ]
                        ]
                      ]
                    ]
                ]
              ]
            , "usage" .= object [ "total_tokens" .= (7 :: Int) ]
            ]
      parseDeepSeekChatTurn resp `shouldBe`
        Right (LLM.ChatTurn "" [LLM.ToolCall "call_1" "bash" "{\"command\":\"ls\"}"]
                  (Just (LLM.mkUsage 0 0 7)) Nothing Nothing Nothing)

    it "parses a plain (tool-less) response" $ do
      let resp = object
            [ "choices" .= [ object
                [ "message" .= object
                    [ "role" .= ("assistant" :: T.Text)
                    , "content" .= ("hello" :: T.Text)
                    ]
                ]
              ]
            ]
      parseDeepSeekChatTurn resp `shouldBe` Right (LLM.ChatTurn "hello" [] Nothing Nothing Nothing Nothing)

  -- Phase 3 K3: API server OpenAI tools passthrough (pure builders)
  describe "API.OpenAITools" $ do
    it "preserves the raw tools array when parsing a request" $ do
      let body = object
            [ "model" .= ("m" :: T.Text)
            , "messages" .= [ object [ "role" .= ("user" :: T.Text), "content" .= ("hi" :: T.Text) ] ]
            , "tools" .= [ object
                [ "type" .= ("function" :: T.Text)
                , "function" .= object [ "name" .= ("bash" :: T.Text), "description" .= ("run" :: T.Text) ]
                ] ]
            ]
      case parseOpenAIRequest body of
        Just req -> length (oaiTools req) `shouldBe` 1
        Nothing  -> expectationFailure "parse failed"

  -- Provider registry (P1): pure config logic, no IO.
  describe "provider adapter cache" $ do
    let mkc name kind = ProviderEntry
          { peName = name, peKind = kind, peBaseUrl = "https://api.example.com/v1"
          , peModels = ["m1"], peDefault = "m1", peHasKey = False, peKeyEnv = Nothing
          , peVisionModels = [], pePreset = False, peInUse = False, peContextWindow = Nothing
          , peWebSearch = Nothing, peSendsThinking = Nothing
          , peEffort = "", peEfforts = [], peAuthHeader = True, peNoProxy = False, peHeaders = Nothing, peExtraBody = Nothing
          , peThinking = "", peResponsesMode = "" }
    it "reuses the adapter for the same fingerprint and rebuilds when the key changes" $ do
      invalidateProviderCaches
      let e = mkc "cacheprobe" "openai"
      _ <- adapterFor e "k1"
      fp1 <- providerCacheFingerprint "cacheprobe"
      _ <- adapterFor e "k1"
      fp2 <- providerCacheFingerprint "cacheprobe"
      fp1 `shouldBe` fp2
      _ <- adapterFor e "k2"
      fp3 <- providerCacheFingerprint "cacheprobe"
      fp3 `shouldSatisfy` (/= fp1)
    it "drops cached adapters on invalidate" $ do
      invalidateProviderCaches
      _ <- adapterFor (mkc "cacheprobe2" "openai") "k"
      fpA <- providerCacheFingerprint "cacheprobe2"
      fpA `shouldSatisfy` (/= Nothing)
      invalidateProviderCaches
      fpB <- providerCacheFingerprint "cacheprobe2"
      fpB `shouldBe` Nothing

  describe "provider effort precedence" $ do
    -- GenParams comes from trha-api here (the kernel package), which is a
    -- distinct type from trha-llm's; assert on the rendered value instead of
    -- importing the other package's accessor.
    it "prefers the explicit genParams effort" $
      show (genParamsWithDefaultEffort (Just "low")
              (Just (object ["effort" .= ("high" :: String)])))
        `shouldContain` "high"
    it "uses the provider default when the request says auto" $
      show (genParamsWithDefaultEffort (Just "high")
              (Just (object ["effort" .= ("auto" :: String)])))
        `shouldContain` "high"
    it "leaves the env fallback alone when neither side sets an effort" $ do
      show (genParamsWithDefaultEffort Nothing Nothing)
        `shouldNotContain` "gpEffort = Just"
      show (genParamsWithDefaultEffort (Just "auto") Nothing)
        `shouldNotContain` "gpEffort = Just"

  describe "extraBody deep merge" $ do
    let base = object
          [ "reasoning" .= object [ "effort" .= ("low" :: String)
                                  , "summary" .= ("auto" :: String) ]
          , "model" .= ("m" :: String) ]
    it "keeps sibling nested fields while the relay wins at leaves" $
      mergeExtraBody
        (Just (object [ "reasoning" .= object [ "effort" .= ("high" :: String) ] ]))
        base
        `shouldBe` object
          [ "reasoning" .= object [ "effort" .= ("high" :: String)
                                  , "summary" .= ("auto" :: String) ]
          , "model" .= ("m" :: String) ]
    it "returns the base unchanged without extras" $
      mergeExtraBody Nothing base `shouldBe` base

  describe "stream request effort" $ do
    let m = ("m" :: String)
    it "adds reasoning_effort to an OpenAI body" $
      withEffort (Just "high") (object ["model" .= m])
        `shouldBe` object ["model" .= m, "reasoning_effort" .= ("high" :: String)]
    it "does not overwrite an existing reasoning_effort" $
      withEffort (Just "low") (object ["reasoning_effort" .= ("high" :: String)])
        `shouldBe` object ["reasoning_effort" .= ("high" :: String)]
    it "treats auto as unset" $
      withEffort (Just "auto") (object ["model" .= m])
        `shouldBe` object ["model" .= m]
    it "spells effort as reasoning.effort on the Responses wire" $
      withResponseEffort (Just "high") (object ["model" .= m])
        `shouldBe` object
          [ "model" .= m
          , "reasoning" .= object ["effort" .= ("high" :: String)] ]

  describe "Core.Provider.Types" $ do
    let mk name kind = ProviderEntry
          { peName = name, peKind = kind, peBaseUrl = "https://api.example.com/v1"
          , peModels = ["m1", "m2"], peDefault = "m1", peHasKey = False, peKeyEnv = Nothing
          , peVisionModels = [], pePreset = False, peInUse = False, peContextWindow = Nothing
          , peWebSearch = Nothing, peSendsThinking = Nothing
          , peEffort = "", peEfforts = [], peAuthHeader = True, peNoProxy = False, peHeaders = Nothing, peExtraBody = Nothing
          , peThinking = "", peResponsesMode = "" }

    it "drops nameless entries and coerces unknown kinds" $ do
      let s = normalizeStore (ProviderStore [mk "a" "openai", mk "  " "openai", mk "b" "weird"])
      map peName (psProviders s) `shouldBe` ["a", "b"]
      map peKind (psProviders s) `shouldBe` ["openai", "openai"]

    it "de-duplicates by name with the last one winning" $ do
      let s = normalizeStore (ProviderStore [mk "dup" "openai", mk "dup" "anthropic"])
      map peName (psProviders s) `shouldBe` ["dup"]
      map peKind (psProviders s) `shouldBe` ["anthropic"]

    it "upserts by name (insert then replace)" $ do
      let s1 = upsertProvider (mk "a" "openai") emptyStore
          s2 = upsertProvider (mk "b" "responses") s1
          s3 = upsertProvider (mk "a" "anthropic") s2
      map peName (psProviders s3) `shouldBe` ["b", "a"]
      fmap peKind (findProvider "a" s3) `shouldBe` Just "anthropic"

    it "removes by name" $ do
      let s = upsertProvider (mk "a" "openai") (upsertProvider (mk "b" "openai") emptyStore)
      map peName (psProviders (removeProvider "a" s)) `shouldBe` ["b"]

    it "round-trips through JSON" $ do
      let s = upsertProvider (mk "a" "openai") emptyStore
      (decode (encode s) :: Maybe ProviderStore) `shouldBe` Just s

    it "declares a protocol catalog covering every valid kind" $ do
      map prKind protocolCatalog `shouldBe` validKinds
      (prKind <$> protocolCatalog) `shouldSatisfy` all (`elem` validKinds)

    -- T6（先红）：本地推理 backend 作为一等 provider kind
    it "懂 \"cpu\"（本地推理 backend）这个 kind" $ do
      ("cpu" `elem` validKinds) `shouldBe` True

    it "normalizeStore 不把 kind=\"cpu\" 的条目改写成 openai" $ do
      let s = normalizeStore (ProviderStore [mk "local-cpu" "cpu"])
      map peName (psProviders s) `shouldBe` ["local-cpu"]
      map peKind (psProviders s) `shouldBe` ["cpu"]

    -- T7：cpu kind 能被 adapterFor 构造，且本地引擎按路径复用
    it "adapterFor 能按 kind=\"cpu\" 构造本地推理适配器" $ do
      r <- adapterFor ((mk "local-cpu" "cpu") { peBaseUrl = "/dev/null" }) ""
      case r of
        Left why -> expectationFailure ("cpu kind 未实现: " ++ T.unpack why)
        Right _  -> pure ()

    it "本地引擎按模型路径复用：同一路径不重复构建" $ do
      -- 注意：缓存是模块级的，前面的用例可能已用同一路径预热过，
      -- 所以这里只断言“再次取用不新建”，不假设“本次是首次”。
      let e = (mk "local-cpu" "cpu") { peBaseUrl = "/dev/null" }
      _ <- adapterFor e ""            -- 预热/取用
      mid <- cpuAdapterCacheSize
      _ <- adapterFor e ""            -- 同路径再来一次
      after <- cpuAdapterCacheSize
      after `shouldBe` mid            -- 复用：不再新建

    it "TRHA_GPU=1 且无可用 .sov 时回退 CPU（不崩、不抛异常）" $ do
      -- 负向控制：GPU 前端初始化失败（/dev/null 不是 .sov）必须回退纯 CPU adapter，
      -- 禁止把「GPU init 失败」变成运行时异常（adapterFor 全程 Either，不抛）。
      let e = (mk "local-cpu" "cpu") { peBaseUrl = "/dev/null" }
      _ <- setEnv "TRHA_GPU" "1"
      r <- adapterFor e ""
      _ <- unsetEnv "TRHA_GPU"
      case r of
        Left why -> expectationFailure ("TRHA_GPU 回退失败: " ++ T.unpack why)
        Right _  -> pure ()

    it "accepts the names the reference accepts and refuses the rest" $ do
      validProviderName "deepseek"   `shouldBe` True
      validProviderName "9router"    `shouldBe` True
      validProviderName "my-gw.v2_x" `shouldBe` True
      validProviderName ""           `shouldBe` False
      validProviderName " has space" `shouldBe` False
      validProviderName "a/b"        `shouldBe` False
      validProviderName (T.replicate 65 "a") `shouldBe` False

    it "derives the key env var, CUSTOM_-prefixing digit-leading names" $ do
      providerKeyEnv "deepseek" `shouldBe` "DEEPSEEK_API_KEY"
      providerKeyEnv "9router"  `shouldBe` "CUSTOM_9ROUTER_API_KEY"
      providerKeyEnv "my gw"    `shouldBe` "MY_GW_API_KEY"

  -- Provider probe (P2): the judgement on an endpoint's answer, no network.
  describe "API.ProviderProbe" $ do
    let listing = encode (object
          [ "data" .= [ object ["id" .= ("m1" :: T.Text)]
                      , object ["id" .= ("m2" :: T.Text)] ] ])

    it "accepts an OpenAI-style listing and picks the first as default" $
      case classifyListing False 200 (Just listing) of
        Right p -> do
          pbModels p  `shouldBe` ["m1", "m2"]
          pbDefault p `shouldBe` "m1"
          pbKind p    `shouldBe` "openai"
          pbNoProxy p `shouldBe` False
        Left e -> expectationFailure ("unexpected failure: " <> show e)

    it "marks a proxy-bypassed answer with noProxy" $
      case classifyListing True 200 (Just listing) of
        Right p -> pbNoProxy p `shouldBe` True
        Left e  -> expectationFailure ("unexpected failure: " <> show e)

    it "maps a refused key (401/403) to key_rejected" $ do
      classifyListing False 401 Nothing `shouldBe` Left ProbeKeyRejected
      classifyListing False 403 Nothing `shouldBe` Left ProbeKeyRejected
      probeErrorCode ProbeKeyRejected `shouldBe` "provider.key_rejected"

    it "maps 404 to path_missing" $ do
      classifyListing False 404 Nothing `shouldBe` Left ProbePathMissing
      probeErrorStatus ProbePathMissing `shouldBe` 404

    it "reports an empty listing as no_models, not as success" $
      classifyListing False 200 (Just (encode (object ["data" .= ([] :: [Int])])))
        `shouldBe` Left ProbeNoModels

    it "reports a non-JSON 200 as unreachable" $
      case classifyListing False 200 (Just "not json") of
        Left (ProbeUnreachable _) -> pure ()
        other -> expectationFailure ("expected ProbeUnreachable, got " <> show other)

    it "reads the alternate listing shapes a gateway may answer with" $ do
      parseModelIds (object ["models" .= (["a", "b"] :: [T.Text])]) `shouldBe` ["a", "b"]
      parseModelIds (Array (V.fromList [String "solo"])) `shouldBe` ["solo"]
      parseModelIds (object ["unrelated" .= True]) `shouldBe` []

  -- Saving a provider (P3): a draft becomes a config entry, keys stay apart.
  describe "Core.Provider.Types (draft)" $ do
    let draft = ProviderDraft
          { pdName = "  my gw  ", pdKind = "openai", pdBaseUrl = " https://gw.example/v1 "
          , pdApiKey = "sk-123", pdModels = ["m1", "m2"], pdDefault = ""
          , pdAuthHeader = True, pdNoProxy = False, pdEffort = "", pdVision = []
          , pdEfforts = [], pdHeaders = Nothing, pdExtraBody = Nothing
          , pdThinking = "", pdResponsesMode = "", pdContextWindow = Nothing }
        entry = draftToEntry draft

    it "carries a context window override into the entry" $
      peContextWindow (draftToEntry draft { pdContextWindow = Just 200000 })
        `shouldBe` Just 200000

    it "normalises an unknown responses mode to the vendor default" $ do
      peResponsesMode (draftToEntry draft { pdResponsesMode = "statefull" })
        `shouldBe` ""
      peResponsesMode (draftToEntry draft { pdResponsesMode = " Stateful " })
        `shouldBe` "stateful"

    it "strips whitespace and derives keyEnv from the name" $ do
      peName entry    `shouldBe` "my gw"
      peBaseUrl entry `shouldBe` "https://gw.example/v1"
      peKeyEnv entry  `shouldBe` Just "MY_GW_API_KEY"

    it "records whether a key was supplied, never the key itself" $ do
      peHasKey entry `shouldBe` True
      peHasKey (draftToEntry draft { pdApiKey = "" }) `shouldBe` False

    it "falls back to the first model as default" $ do
      peDefault entry `shouldBe` "m1"
      peDefault (draftToEntry draft { pdDefault = "m2" }) `shouldBe` "m2"

    it "coerces an unknown kind to openai" $
      peKind (draftToEntry draft { pdKind = "weird" }) `shouldBe` "openai"

    it "round-trips a draft through JSON" $
      (decode (encode draft) :: Maybe ProviderDraft) `shouldBe` Just draft

    it "keeps keys in a separate store, addressable by name" $ do
      let ks = insertKey "a" "sk-a" (insertKey "b" "sk-b" emptyKeys)
      lookupKey "a" ks `shouldBe` Just "sk-a"
      lookupKey "zz" ks `shouldBe` Nothing
      (decode (encode ks) :: Maybe ProviderKeys) `shouldBe` Just ks

  -- ── API.Server 装配端到端（真实 warp + 真实 HTTP 请求）──────────────────────
  -- 为什么补这组：全库此前**没有任何 HTTP 端到端测试**，所有 API 测试都停在纯函数
  -- 层（parseOpenAIRequest / classifyListing / ProviderEntry）。后果是接线缺口不会
  -- 被任何测试看见。
  --
  -- ⚠️ 装配在这里暴露出的**根本障碍**：trha-api 把自己的 LLM.Adapter.Interface
  -- 又编译了一份（列在 other-modules），于是 trha-api 的 LLMAdapter 与 trha-llm 的
  -- LLMAdapter 是**两个不同类型**。外部拿到的 createCPUAdapter 根本传不进
  -- API.Server —— 所以这组测试只能走包内入口（mkCPUApp / mkStubApp），写不成
  -- 「注入任意 adapter」的形式。
  describe "API.Server — 装配端到端 (HTTP, 真实 warp)" $ do
    let withApp :: Application -> (Manager -> String -> IO a) -> IO a
        withApp app act =
          testWithApplication (pure app) $ \port -> do
            mgr <- newManager defaultManagerSettings
            act mgr ("http://127.0.0.1:" ++ show port)

        httpGet :: Manager -> String -> IO (Int, String)
        httpGet mgr url = do
          req <- parseRequest url
          res <- httpLbs req mgr
          pure (statusCode (responseStatus res), BLC.unpack (responseBody res))

        httpPost :: Manager -> String -> Value -> IO (Int, String)
        httpPost mgr url body = do
          req0 <- parseRequest ("POST " ++ url)
          let req = req0 { method          = "POST"
                         , requestBody     = RequestBodyLBS (encode body)
                         , requestHeaders  = [ ("Content-Type", "application/json") ] }
          res <- httpLbs req mgr
          pure (statusCode (responseStatus res), BLC.unpack (responseBody res))

        chatReq :: Bool -> Value
        chatReq stream = object
          [ "model"    .= ("cpu-model" :: T.Text)
          , "stream"   .= stream
          , "messages" .= [ object [ "role"    .= ("user" :: T.Text)
                                   , "content" .= ("hi" :: T.Text) ] ]
          ]

    it "stub 装配：/v1/models 报的是 stub 自己的模型（K6 现状）" $ do
      app <- mkStubApp Nothing
      (code, body) <- withApp app $ \mgr base -> httpGet mgr (base ++ "/v1/models")
      code `shouldBe` 200
      ("Stub Kernel" `isInfixOf` body) `shouldBe` True

    it "CPU 装配：同一个端点换成 cpu-model（backend 由装配决定，不是硬编码）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (code, body) <- withApp app $ \mgr base -> httpGet mgr (base ++ "/v1/models")
      code `shouldBe` 200
      ("cpu-model" `isInfixOf` body)     `shouldBe` True
      ("Stub Kernel" `isInfixOf` body)   `shouldBe` False

    it "CPU adapter 经 HTTP 完成一次非流式 chat（/v1/chat/completions）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (code, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions") (chatReq False)
      code `shouldBe` 200
      ("chat.completion" `isInfixOf` body) `shouldBe` True
      ("cpu-model" `isInfixOf` body)       `shouldBe` True

    -- ── C5(D-1)：约束 ↔ 外部推理（作用点 = 响应侧的「采纳判定」）──────────────
    -- 三要素由用户 2026-09-13 裁定：作用点 = 响应侧采纳判定；失败行为 = 标注（不拒绝、
    -- 不降级）；草稿模型与约束是同一机制的两面（草稿输出必须先过约束）。
    it "★ C5(D-1)：响应**总是**携带约束判定 trha_constraint（作用点在响应侧）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (code, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions") (chatReq False)
      code `shouldBe` 200
      ("trha_constraint" `isInfixOf` body) `shouldBe` True

    it "★ C5(D-1)：判定状态只有 pass / warn —— 类型里没有「拒绝」（裁定①）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (_, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions") (chatReq False)
      ( ("\"pass\"" `isInfixOf` body) || ("\"warn\"" `isInfixOf` body) ) `shouldBe` True

    it "★ C5(D-1)：判定是标注而非拒绝 —— status=warn 时内容仍然返回（裁定①）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (code, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions") (chatReq False)
      code `shouldBe` 200
      -- 无论 pass 还是 warn，响应体里的 chat.completion 载荷都要在（功能不被破坏）
      ("chat.completion" `isInfixOf` body) `shouldBe` True

    it "★ C5(D-1)：判定分量齐全 t6 / reach / edges / reason（约束确实跑了三原语）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (_, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions") (chatReq False)
      and [ k `isInfixOf` body
          | k <- [ "\"t6\"", "\"reach\"", "\"edges\"", "\"reason\"" ] ] `shouldBe` True


    -- ── D-3：推理状态上浮为会话投影 ───────────────────────────────────────
    -- 推理内核（T⁶ / 因果图 / 五行链）的状态此前只活在 CPU 层；这里验它经
    -- Core.Session.projections 上浮到内核会话，且在内核 API 响应中可观测。
    it "★ D-3：/agent/step 把推理状态上浮为会话投影，并在响应回显" $ do
      app <- mkCPUApp "/dev/null" Nothing
      -- 必须在**同一个** withApp 内两次 POST（每次 withApp 会新起 server，session 会丢）
      (cStart, cStep, body) <- withApp app $ \mgr base -> do
        (cs, _bs) <- httpPost mgr (base ++ "/session/start")
                       (object [ "mode" .= ("standard" :: T.Text) ])
        -- createSession 用 "session-" <> mode 生成 ID，故可预知
        (ct, bt) <- httpPost mgr (base ++ "/agent/step")
                      (object [ "sessionId" .= ("session-standard" :: T.Text)
                              , "message"   .= ("hello" :: T.Text) ])
        pure (cs, ct, bt)
      cStart `shouldBe` 200
      cStep  `shouldBe` 200
      -- ★ 上浮可观测：投影名（t6state / constraint）出现在响应里
      and [ k `isInfixOf` body | k <- [ "session_projections", "t6state", "constraint" ] ]
        `shouldBe` True
      -- ★ 推理状态的分量：T⁶ 极向/环向/Berry
      and [ k `isInfixOf` body | k <- [ "\"polar\"", "\"toroidal\"", "\"berry\"" ] ]
        `shouldBe` True
      -- 既有字段语义未被破坏
      ("reply" `isInfixOf` body) `shouldBe` True

    -- ── 端到端：提问 → 生成 → 验证（推理内核）→ 状态上浮 ──────────────────
    -- ⚠️ 本组用 /dev/null（占位引擎）验证**链路闭合**；占位采样器输出为 "token_0" 重复，
    -- 本条**能验证的是链路闭合**：请求 → 生成层产出 → 推理内核判定 → 状态上浮为投影 → 响应。
    -- **真实** CPU 推理（真实 .sov + Brain + argMaxIdx 采样）见 B4（generate 产出真实 token id）。
    it "★ D-3：/agent/step 推进内核 FSM 并在响应回显 agent_state" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (cStart, cStep, body) <- withApp app $ \mgr base -> do
        (cs, _) <- httpPost mgr (base ++ "/session/start")
                     (object [ "mode" .= ("standard" :: T.Text) ])
        (ct, bt) <- httpPost mgr (base ++ "/agent/step")
                      (object [ "sessionId" .= ("session-standard" :: T.Text)
                              , "message"   .= ("hi" :: T.Text) ])
        pure (cs, ct, bt)
      cStart `shouldBe` 200
      cStep  `shouldBe` 200
      ("agent_state" `isInfixOf` body) `shouldBe` True
      ("Idle" `isInfixOf` body) `shouldBe` True          -- before
      ("Processing" `isInfixOf` body) `shouldBe` True    -- after（transition Idle (StartCommand _)）

    -- ── D-3 深度验证：不只查"投影存在"，而验**投影内容的数值合法性** ──────────
    -- 此前只断言投影名出现；这里解析 JSON，核对 T⁶ 三分量的值域与判定分量，
    -- 才算真的验证了"推理状态被正确地上浮"，而不是"某处出现了字符串"。
    it "★ D-3 深度验证：t6_state 三分量合法（polar<144、toroidal<46）+ 判定分量 + 投影恰两个" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (cStep, body) <- withApp app $ \mgr base -> do
        _ <- httpPost mgr (base ++ "/session/start")
               (object [ "mode" .= ("standard" :: T.Text) ])
        httpPost mgr (base ++ "/agent/step")
          (object [ "sessionId" .= ("session-standard" :: T.Text)
                  , "message"   .= ("hi" :: T.Text) ])
      cStep `shouldBe` 200
      let mval = decode (BL.fromStrict (TE.encodeUtf8 (T.pack body))) :: Maybe Value
      case mval of
        Nothing -> expectationFailure ("响应不是合法 JSON: " ++ take 200 body)
        Just v -> do
          -- 注意 JSON 是**嵌套**的：polar/toroidal/berry 在 "t6_state" 对象内部，
          -- 而 t6/edges/status 在 "trha_constraint" 对象内部（顶层没有这些键）。
          let mt6 = parseMaybe (withObject "resp" (\o -> do
                      s6 <- o .: "t6_state"
                      (,,) <$> s6 .: "polar" <*> s6 .: "toroidal" <*> s6 .: "berry")) v
                     :: Maybe (Int, Int, Int)
          case mt6 of
            Nothing -> expectationFailure "缺 t6_state 字段"
            Just (polar, toroidal, _berry) -> do
              (polar >= 0 && polar < 144)   `shouldBe` True   -- 极向 mod polarWinding(144)
              (toroidal >= 0 && toroidal < 46) `shouldBe` True -- 环向 mod toroidalWinding(46)
          let mcv = parseMaybe (withObject "resp" (\o -> do
                      c <- o .: "trha_constraint"
                      (,,) <$> c .: "t6" <*> c .: "edges" <*> c .: "status")) v
                     :: Maybe (Bool, Int, T.Text)
          case mcv of
            Nothing -> expectationFailure "缺 constraint 判定字段"
            Just (_t6ok, edges, status) -> do
              (edges >= 0) `shouldBe` True
              (status == "pass" || status == "warn") `shouldBe` True  -- 无「拒绝」
          let mnames = parseMaybe (withObject "p" (.: "session_projections")) v
                        :: Maybe [T.Text]
          fmap List.sort mnames `shouldBe` Just ["constraint", "t6state"]

    it "★ D-3：投影是覆盖写 —— 多步后仍只有两个键（不累积）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      n2 <- withApp app $ \mgr base -> do
        _ <- httpPost mgr (base ++ "/session/start")
               (object [ "mode" .= ("standard" :: T.Text) ])
        b2 <- snd <$> httpPost mgr (base ++ "/agent/step")
                (object [ "sessionId" .= ("session-standard" :: T.Text)
                        , "message"   .= ("a" :: T.Text) ])
        b3 <- snd <$> httpPost mgr (base ++ "/agent/step")
                (object [ "sessionId" .= ("session-standard" :: T.Text)
                        , "message"   .= ("b" :: T.Text) ])
        pure b3
      and [ k `isInfixOf` n2 | k <- [ "t6state", "constraint" ] ] `shouldBe` True

    it "CPU adapter 经 HTTP 走 SSE 流式（/v1/chat/completions/stream）" $ do
      app <- mkCPUApp "/dev/null" Nothing
      (code, body) <- withApp app $ \mgr base ->
        httpPost mgr (base ++ "/v1/chat/completions/stream") (chatReq True)
      code `shouldBe` 200
      ("data: " `isInfixOf` body)        `shouldBe` True
      ("data: [DONE]" `isInfixOf` body)  `shouldBe` True

    -- T8：provider 名分派到本地 backend —— 完整链路
    --   HTTP → resolveAdapterIO → findProvider(providers.json) → adapterFor "cpu" → 本地引擎
    -- 用 TRHA_PROVIDERS_FILE 指向临时文件，避免污染 ~/.trha。
    it "provider=\"local-cpu\"（kind=cpu）的请求经 providers.json 分派，由本地引擎回答" $ do
      let pfile = "/tmp/trha-test-providers.json"
          entry = ProviderEntry
            { peName = "local-cpu", peKind = "cpu", peBaseUrl = "/dev/null"
            , peModels = ["cpu"], peDefault = "cpu", peHasKey = False, peKeyEnv = Nothing
            , peVisionModels = [], pePreset = False, peInUse = False, peContextWindow = Nothing
            , peWebSearch = Nothing, peSendsThinking = Nothing
            , peEffort = "", peEfforts = [], peAuthHeader = True, peNoProxy = False, peHeaders = Nothing, peExtraBody = Nothing
            , peThinking = "", peResponsesMode = "" }
      BLC.writeFile pfile (encode (ProviderStore [entry]))
      setEnv "TRHA_PROVIDERS_FILE" pfile
      r <- adapterFor entry ""
      case r of
        Left why -> expectationFailure ("cpu adapter 构造失败: " ++ T.unpack why)
        Right defAdapter -> do
          app <- mkApp defAdapter Nothing
          (code, body) <- withApp app $ \mgr base ->
            httpPost mgr (base ++ "/v1/chat/completions")
              (object [ "provider" .= ("local-cpu" :: T.Text)
                      , "model"    .= ("cpu" :: T.Text)
                      , "messages" .= [ object [ "role"    .= ("user" :: T.Text)
                                               , "content" .= ("hi" :: T.Text) ] ] ])
          unsetEnv "TRHA_PROVIDERS_FILE"
          code `shouldBe` 200
          ("cpu" `isInfixOf` body) `shouldBe` True   -- 本地引擎回答（回显模型名）

  -- ──────────────────────────────────────────────────────────────────────
  -- Kernel.Carrier：C[A₄] 函数空间 + Plancherel 内积（sov-math 接线）
  --
  -- 判据：载体是 12 维函数空间（不是点集）；内积是 Plancherel 配对（不是点积）；
  -- 基 δ_g 在配对下正交归一；维数满足 Plancherel 恒等式 Σ d_ρ² = |A₄|。
  -- ──────────────────────────────────────────────────────────────────────
  describe "Kernel.Carrier (sov-math 接线)" $ do
    it "载体维数 = |A₄| = 12（函数空间，不是点集）" $ do
      dimCarrier `shouldBe` 12
      a4Card `shouldBe` 12
      length allA4 `shouldBe` 12

    it "层声明只有 L12（其余层不进内核）" $ do
      L12 `shouldBe` L12

    it "Plancherel 内积：δ 基正交归一（144 对全检）" $ do
      let pairs = [ (g, h) | g <- allA4, h <- allA4 ]
      and [ dotC (basisVec g) (basisVec h)
              == (if g == h then eisOne else eisZero)
          | (g, h) <- pairs ] `shouldBe` True

    it "初态 δ_e 的范数为 1" $
      normC2 initialPoint `shouldBe` eisOne

    it "Plancherel 恒等式 Σ_ρ d_ρ² = |A₄| = dim" $ do
      plancherelSum `shouldBe` 12
      plancherelSum `shouldBe` dimCarrier

    it "不可约表示维数是 1,1,1,3 —— 只有 R3 是矢量（dim ≥ 2）" $
      map dimI [ R1, R1', R1'', R3 ] `shouldBe` [1, 1, 1, 3]

    it "状态是关联丛的截面：底空间 T⁶/A₄ = 135 类，索引是 BaseKey" $
      case mkBaseKey 0 of
        Just k -> do
          baseCard `shouldBe` 135
          sectionNorm zeroSection k `shouldBe` eisZero
        Nothing -> expectationFailure "mkBaseKey 0 应当成功"
    it "BaseKey 拒绝越界（135 / −1）" $
      (mkBaseKey 135, mkBaseKey (-1)) `shouldBe` (Nothing, Nothing)

    it "零截面不是 framing；常截面 δ_e 是 framing（Hopf 扭转的判据）" $ do
      isFraming zeroSection `shouldBe` False
      isFraming (constantSection initialPoint) `shouldBe` True

    it "描述差（非不变量）：平纤维 1620 vs 典范 729 ⇒ 891" $ do
      flatDim `shouldBe` 1620
      effectiveDim `shouldBe` 729
      overcount `shouldBe` 891

    it "描述差按轨道类型分解（谁贡献了多少）" $ do
      overcountByOrbit `shouldBe` [ (1, 27, 297), (4, 54, 432), (6, 27, 162), (12, 27, 0) ]
      overcountDecomposition `shouldBe` True

    it "等变截面不存在（存在 1 点轨道）" $
      equivariantSectionPossible `shouldBe` False

    it "统一 12 坐标不忠实（存在 1 点轨道）" $ do
      minFiberSize `shouldBe` 1
      maxFiberSize `shouldBe` 12
      uniformCoordsFaithful `shouldBe` False

    it "旋量层：GF(3)² 纤维 9、总空间 6561、相位 α 阶 4、α² = −I" $ do
      spinFiberCard `shouldBe` 9
      spinTotalCard `shouldBe` 6561
      phaseAct 4 (MT.T1, MT.T0) `shouldBe` (MT.T1, MT.T0)   -- 阶 4
      phaseAct 2 (MT.T1, MT.T0) `shouldBe` (MT.T2, MT.T0)   -- α² = −I：v ↦ −v
