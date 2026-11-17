-- | W4 端到端：@cpu@ kind 的 recipe 流解析管道。
--
-- 断言的是**解析语义**（与 Rust 侧 stream 测试同构）：
-- 思考段/正文分割、DSML 工具调用块、usage 记账——
-- 产生器（token 序列来源）可插拔，真推理引擎接入后本测试不改。
-- 走真实 ProviderRuntime 路径（adapterFor 的 "cpu" 分支）。
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module CpuProviderSpec (cpuProviderSpec) where

import Control.Exception (bracket_)
import Data.IORef
import Data.Text (Text)
import qualified Data.Aeson as Aeson
import qualified Data.Text as T
import System.Environment (setEnv, unsetEnv)
import System.Directory (getTemporaryDirectory)
import System.FilePath ((</>))
import Test.Hspec

import API.ProviderRuntime (adapterFor)
import Core.Provider.Types
import LLM.Adapter.Interface (LLMAdapter(..), StreamCall)
import LLM.Recipe.FFI (recipeDispatch)
import LLM.Adapter.Types
  ( ChatMessage(..)
  , ChatTurn(..)
  , GenParams(..)
  , defaultGenParams
  , StreamChunk(..)
  , ToolCall(..)
  , ToolSpec(..)
  )

cpuEntry :: ProviderEntry
cpuEntry = ProviderEntry
  { peName = "cpu-local", peKind = "cpu"
  , peBaseUrl = "/home/yanli/work/trha/models/20260721-033421_step31000"
  , peModels = [], peDefault = "deepseek-flash"
  , peHasKey = False, peKeyEnv = Nothing, peVisionModels = []
  , pePreset = True, peInUse = False, peContextWindow = Nothing
  , peWebSearch = Nothing, peSendsThinking = Nothing, peEffort = ""
  , peEfforts = [], peHeaders = Nothing, peExtraBody = Nothing
  , peThinking = "", peResponsesMode = ""
  , peAuthHeader = False, peNoProxy = True
  }

sampleMsgs :: [ChatMessage]
sampleMsgs =
  [ ChatSystem "You are helpful."
  , ChatUser "本地推理测试"
  ]

sampleSpecs :: [ToolSpec]
sampleSpecs = [ ToolSpec "cpu_read" "读取本地文件" (Aeson.object [("type" Aeson..= ("object" :: T.Text))]) False ]

-- | W5 多模态同款：TRHA_CPU_TOKENS 的测试级设置/恢复（进程内全局 env）。
withCpuTokensFile :: FilePath -> IO a -> IO a
withCpuTokensFile fp = bracket_ (setEnv "TRHA_CPU_TOKENS" fp)
                                (unsetEnv "TRHA_CPU_TOKENS")

cpuProviderSpec :: Spec
cpuProviderSpec =
  describe "cpu kind — recipe 流解析管道 (W4)" $ do
    it "adapterFor 构建 cpu 适配器成功" $ do
      r <- adapterFor cpuEntry ""
      case r of
        Left why  -> expectationFailure ("adapter build failed: " ++ T.unpack why)
        Right _   -> pure ()

    -- 流式路径的语义主测：思考段（</think> 收尾）→ 正文 → DSML 工具调用 → usage
    it "流路径：思考/正文分割 + DSML 工具调用 + usage" $ do
      r <- adapterFor cpuEntry ""
      case r of
        Left why -> expectationFailure ("adapter build failed: " ++ T.unpack why)
        Right adapter -> do
          -- 诊断：convert 是否成功
          conv <- recipeDispatch "convert" (T.pack "{\"kind\":\"cc\",\"request\":{\"model\":\"deepseek-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}}")
          mapM_ (putStrLn . ("DBG convert: " ++) . show) conv
          evsRef <- newIORef ([] :: [StreamChunk])
          turn <- llmChatToolsStream adapter sampleMsgs sampleSpecs
                    defaultGenParams $ \ev ->
            modifyIORef evsRef (ev :)
          evs <- reverse <$> readIORef evsRef
          mapM_ (putStrLn . ("DBG ev: " ++) . show) evs
          putStrLn ("DBG turn: " ++ show turn)

          -- 语义 1：思考段与正文分割（Reasoning 先于 Delta，互不混入）
          let reasoningText = T.concat [ t | ChunkReasoning t <- evs ]
              contentText   = T.concat [ t | ChunkDelta t <- evs ]
          reasoningText `shouldSatisfy` not . T.null
          contentText `shouldSatisfy` not . T.null
          contentText `shouldSatisfy` not . T.isInfixOf "思考"

          -- 语义 2：DSML 工具调用块 → ChunkToolCallAt（name=cpu_read）
          let toolNames = [ nm | ChunkToolCallAt _ _ nm _ <- evs ]
          toolNames `shouldSatisfy` (elem "cpu_read")

          -- 语义 3：usage 记账（CC generator 的 finish chunk）
          let usages = [ u | ChunkDone u <- evs ]
          usages `shouldSatisfy` not . null

          -- turn 聚合契约
          ctError turn `shouldBe` Nothing
          ctToolCalls turn `shouldSatisfy` (any ((== "cpu_read") . tcName))

    -- 产生器可插拔：TRHA_CPU_TOKENS 指定自定义序列（纯文本 token，无特殊
    -- token——整轮全是 reasoning，正文为空），且不出工具调用
    it "产生器可插拔：TRHA_CPU_TOKENS 覆盖默认序列" $ do
      tmp <- getTemporaryDirectory
      let tokensFp = tmp </> "trha-cpu-custom-tokens.txt"
      setEnv "TRHA_CPU_TOKENS" tokensFp
      writeFile tokensFp "10\n20\n30\n"   -- 任意 ID：解码为无意义 piece
      r <- adapterFor cpuEntry ""
      case r of
        Left why -> expectationFailure ("adapter build failed: " ++ T.unpack why)
        Right adapter -> do
          evsRef <- newIORef ([] :: [StreamChunk])
          turn <- llmChatToolsStream adapter sampleMsgs sampleSpecs
                    defaultGenParams $ \ev ->
            modifyIORef evsRef (ev :)
          evs <- reverse <$> readIORef evsRef
          -- 自定义序列无 </think>：全部进 reasoning，无正文无工具
          let reasoningText = T.concat [ t | ChunkReasoning t <- evs ]
              contentText   = T.concat [ t | ChunkDelta t <- evs ]
          reasoningText `shouldSatisfy` not . T.null
          contentText `shouldBe` ""
          ctError turn `shouldBe` Nothing
      unsetEnv "TRHA_CPU_TOKENS"

-- 事件记录辅助（与 providerEvents 同形：内核事件直收）。
-- 流式管线的事件次序即内核语义：Start 前置、Delta/Reasoning 交错、Usage 收尾。
