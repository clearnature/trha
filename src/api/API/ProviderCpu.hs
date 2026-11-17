{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | @cpu@ kind——内核内本地推理后端（W4）。
--
-- 架构定性（2026-11-17）：@models/@ 的三值 checkpoint 与 webgpu 计算底座
-- 尚不能产出 token 流（无 tokenizer\/前向\/采样），因此本模块交付 W4 的
-- **解析管道**：产生器（token IDs）→ recipe stream 会话（InferenceChunk →
-- StreamProcessor → CC chunks）→ 内核 StreamChunk 事件。产生器可插拔：
--
--   * @TRHA_CPU_TOKENS@ 指向文件（每行一个 token ID）——真实后端或测试
--     固定序列；
--   * 缺省走内置样例文本经 @encode_text@（含 @</think>@ 与 DSML
--     added-vocab token，tokenizer 与流解析同一份，语义自洽）。
--
-- 真推理引擎（webgpu\/BitNet 前向）成熟后只替换产生器，解析层与 provider
-- 接口不变。回退：@TRHA_RECIPE_STREAM=0@ 时不走流解析，样例文本直接作为
-- 纯文本 delta（管道降级，仍可用）。
module API.ProviderCpu
  ( cpuRecipeAdapter
  ) where

import System.IO.Error (catchIOError)
import Control.Monad (forM_, void)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (foldl')
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import System.Environment (lookupEnv)

import LLM.Adapter.Interface (LLMAdapter(..), StreamCall)
import LLM.Adapter.Types
  ( ChatMessage(..)
  , ChatTurn(..)
  , Message(..)
  , ModelInfo(..)
  , Role(..)
  , StreamChunk(..)
  , ToolCall(..)
  , ToolSpec(..)
  , mkUsage
  , messageContent
  , messageRole
  )

import LLM.Recipe.FFI
  ( recipeDispatch
  , recipeInit
  , recipeStreamRun
  )

-- ---------------------------------------------------------------------------
-- 产生器：token IDs
-- ---------------------------------------------------------------------------

-- | 内置样例补全：思考段（以 @</think>@ 收尾）→ 应答 → DSML 工具调用块。
-- V4.1 输出不以 @<think>@ 开头（thinking_initial_stage 已置 Reasoning）。
cpuSampleText :: Text
cpuSampleText = T.concat
  [ "本地推理思考中，检查工具与上下文。"
  , "</think>"
  , "本地推理应答完成。"
  , "<｜DSML｜tool_calls>\n"
  , "<｜DSML｜invoke name=\"cpu_read\">\n"
  , "</｜DSML｜invoke>\n"
  , "</｜DSML｜tool_calls>"
  ]

-- | 产生器：@TRHA_CPU_TOKENS@ 文件（每行一个 token ID）优先；文件缺失或
-- 不可读时回退内置样例经 @encode_text@。
cpuTokenIds :: IO [Int]
cpuTokenIds = do
  mfp <- lookupEnv "TRHA_CPU_TOKENS"
  case mfp of
    Nothing -> sampleIds
    Just fp -> do
      r <- catchIOError (Just . lines . T.unpack . TE.decodeUtf8
                          <$> BS.readFile fp)
                        (const (pure Nothing))
      case r of
        Just ls | not (null ls) -> pure (map readInt ls)
        _ -> sampleIds
  where
    readInt l = case reads l of
      [(n, _)] -> n
      _        -> 0

-- | 内置样例经 encode_text：tokenizer 与流解析同一份，语义自洽。
sampleIds :: IO [Int]
sampleIds = do
  let payload = Aeson.encode (object ["text" .= cpuSampleText])
  recipeDispatch "encode_text" (TE.decodeUtf8 (BL.toStrict payload)) >>= \case
    Just (Object o) -> case KM.lookup (AK.fromText "token_ids") o of
      Just (Aeson.Array vs) -> pure [ truncate (realToFrac n :: Double)
                                    | Aeson.Number n <- V.toList vs ]
      _                     -> pure []
    _ -> pure []

-- ---------------------------------------------------------------------------
-- CC 请求构造（流会话输入）
-- ---------------------------------------------------------------------------

-- | trha 模型别名 → 库校验的 API 名（FFI 直调不经 HTTP 归一层，这里补）。
recipeModelAlias :: Text -> Text
recipeModelAlias "deepseek-flash"  = "DeepSeek-V4.1-Flash"
recipeModelAlias "deepseek-v4-pro" = "DeepSeek-V4-Pro"
recipeModelAlias m                 = m

-- | 内核消息 → CC JSON（cpu 管道只承担解析，对话内容原样映射）。
cpuCcRequest :: [ChatMessage] -> [ToolSpec] -> Text -> Text
cpuCcRequest msgs specs model =
  TE.decodeUtf8 (BL.toStrict (Aeson.encode (object
    [ "model" .= recipeModelAlias model
    , "messages" .= map msgJson msgs
    , "tools" .= map specJson specs
    , "stream" .= True
    ])))
  where
    msgJson m = case m of
      ChatSystem c      -> object ["role" .= ("system" :: Text), "content" .= c]
      ChatUser c        -> object ["role" .= ("user" :: Text), "content" .= c]
      ChatAssistant c _ -> object ["role" .= ("assistant" :: Text), "content" .= c]
      ChatAssistantThought c _ _ _ ->
        object ["role" .= ("assistant" :: Text), "content" .= c]
      ChatTool cid c -> object
        [ "role" .= ("tool" :: Text), "tool_call_id" .= cid, "content" .= c ]
    specJson sp = object
      [ "type" .= ("function" :: Text)
      , "function" .= object
          [ "name" .= tsName sp
          , "description" .= tsDescription sp
          , "parameters" .= tsParameters sp
          ]
      ]

-- ---------------------------------------------------------------------------
-- CC chunk JSON → ChatTurn（stream 与 blocking 共用）
-- ---------------------------------------------------------------------------

-- | 工具调用聚合状态：(idx, id, name, arguments)。
type ToolAcc = [(Int, Text, Text, Text)]

-- | CC chunk JSON → 内核事件并聚合 ChatTurn。工具调用在流尾按序补发
-- （ChunkToolCallAt idx id name arguments，与 openAI 适配器同形状）。
assemble :: (StreamChunk -> IO ()) -> [Aeson.Value] -> IO ChatTurn
assemble onEvent chunks = do
  (content, reasoning, toolAcc, musage) <-
    go ("" :: Text, "" :: Text, [] :: ToolAcc, Nothing :: Maybe Aeson.Value) chunks
  forM_ (reverse toolAcc) $ \(i, tid, nm, args) ->
    onEvent (ChunkToolCallAt i tid nm args)
  pure ChatTurn
    { ctContent = content
    , ctReasoning = Just reasoning
    , ctReasoningSignature = Nothing
    , ctToolCalls = [ ToolCall { tcId = tid, tcName = nm, tcArguments = args }
                    | (i, tid, nm, args) <- reverse toolAcc ]
    , ctUsage = Just $ case musage of
        Just (Object u) -> mkUsage (intAt (Object u) "prompt_tokens")
                                   (intAt (Object u) "completion_tokens")
                                   (intAt (Object u) "total_tokens")
        _               -> mkUsage 0 0 0
    , ctError = Nothing
    }
  where
    go :: (Text, Text, ToolAcc, Maybe Aeson.Value) -> [Aeson.Value]
       -> IO (Text, Text, ToolAcc, Maybe Aeson.Value)
    go acc [] = pure acc
    go acc (y:ys) = do acc' <- step acc y; go acc' ys
    step :: (Text, Text, ToolAcc, Maybe Aeson.Value) -> Aeson.Value
         -> IO (Text, Text, ToolAcc, Maybe Aeson.Value)
    step (content, reasoning, tools, musage) chunk =
      let choices = listAt chunk "choices"
          delta = case choices of
            (Object c0:_) -> fromMaybe Aeson.Null (subOf (Object c0) "delta")
            _             -> Aeson.Null
          mcontent = strAt delta "content"
          mreason  = strAt delta "reasoning_content"
          mtools   = listAt delta "tool_calls"
          tools' = foldl' accumulate tools mtools
          musage' = case subOf chunk "usage" of
            Just u@(Object _) -> Just u
            _                 -> musage
      in do
        forM_ mreason (onEvent . ChunkReasoning)
        forM_ mcontent (onEvent . ChunkDelta)
        -- usage 的 finish chunk：显式转成 ChunkDone（消费方按事件记账）
        case musage' of
          Just u@(Object _) ->
            onEvent (ChunkDone (mkUsage (intAt u "prompt_tokens")
                                        (intAt u "completion_tokens")
                                        (intAt u "total_tokens")))
          _ -> pure ()
        pure ( content <> fromMaybe "" mcontent
             , reasoning <> fromMaybe "" mreason
             , tools'
             , musage' )
    accumulate :: ToolAcc -> Aeson.Value -> ToolAcc
    accumulate accs tv =
      let idx = intAt tv "index"
          tid = fromMaybe "" (strAt tv "id")
          fnm = fromMaybe Aeson.Null (subOf tv "function")
          nm = fromMaybe "" (strAt fnm "name")
          argsD = fromMaybe "" (strAt fnm "arguments")
          go :: ToolAcc -> ToolAcc
          go [] = [(idx, tid, nm, argsD)]
          go ((i, id0, n0, a0):rest)
            | i == idx  = (i, id0, if T.null n0 then tid else n0, a0 <> argsD) : rest
            | otherwise = (i, id0, n0, a0) : go rest
      in go accs

    objOf (Object o) = o
    objOf _          = KM.empty
    subOf v k = case v of
      Object o -> KM.lookup (AK.fromText k) o
      _        -> Nothing
    listAt v k = case v of
      Object o -> case KM.lookup (AK.fromText k) o of
        Just (Aeson.Array vs) -> V.toList vs
        _                     -> []
      _ -> []
    strAt v k = case v of
      Object o -> case KM.lookup (AK.fromText k) o of
        Just (String t) -> Just t
        _               -> Nothing
      _ -> Nothing
    intAt v k = case v of
      Object o -> case KM.lookup (AK.fromText k) o of
        Just (Aeson.Number n) -> truncate (realToFrac n :: Double)
        _                     -> 0
      _ -> 0

-- ---------------------------------------------------------------------------
-- 流式与阻塞入口
-- ---------------------------------------------------------------------------

-- | vendored V4.1 tokenizer（与 LLM.Recipe.FFI 的 defaultTokenizerPath 同源；
-- 仓库根相对路径——内核从仓库根启动）。
defaultTokenizerPath :: FilePath
defaultTokenizerPath = "3rdparty/trha-recipe/static/tokenizers/v41/tokenizer.json"

-- | 一轮补全的完整管线（流式与阻塞共用）。
runCpuTurn :: (StreamChunk -> IO ()) -> [ChatMessage] -> [ToolSpec] -> IO ChatTurn
runCpuTurn onEvent msgs specs = do
  -- FFI 状态幂等初始化：encode_text 与流会话都要求已加载 tokenizer
  recipeInit
  ids <- cpuTokenIds
  putStrLn ("[cpu] ids=" ++ show (length ids))
  let ccReq = cpuCcRequest msgs specs "deepseek-flash"
  raw <- recipeStreamRun "cc" ccReq (Just defaultTokenizerPath) ids
           "chatcmpl-cpu" "deepseek-flash"
  case raw of
    Nothing -> failTurn "cpu stream run failed (FFI unavailable)"
    Just v  -> assemble onEvent (chunksOf v)
  where
    failTurn msg = do
      onEvent (ChunkError msg)
      pure ChatTurn { ctContent = "", ctReasoning = Nothing
                    , ctReasoningSignature = Nothing, ctToolCalls = []
                    , ctUsage = Nothing, ctError = Just msg }
    chunksOf (Object o) = case KM.lookup (AK.fromText "chunks") o of
      Just (Aeson.Array vs) -> V.toList vs
      _                     -> []
    chunksOf _ = []

-- | 内核 Message → 流管线用的 ChatMessage（工具消息带 id）。
toChatMessages :: [Message] -> [ChatMessage]
toChatMessages = map conv
  where
    conv m = case messageRole m of
      System    -> ChatSystem (messageContent m)
      User      -> ChatUser (messageContent m)
      Assistant -> ChatAssistant (messageContent m) []

-- | @cpu@ kind 的适配器。@modelPath@ 目前只是标识（产生器不依赖它；
-- 真推理引擎接入后由此定位模型文件）。
cpuRecipeAdapter :: Text -> IO LLMAdapter
cpuRecipeAdapter modelPath = pure LLMAdapter
  { llmChat = \msgs ->
      -- 非流式调用复用同管线（事件丢弃，取聚合结果）
      do
        turn <- runCpuTurn (const (pure ())) (toChatMessages msgs) []
        pure ( [ChunkDelta (ctContent turn) | not (T.null (ctContent turn))]
            ++ maybe [] (\u -> [ChunkDone u]) (ctUsage turn)
            ++ maybe [] (\e -> [ChunkError e]) (ctError turn) )
  , llmChatTools = \msgs specs _gp -> runCpuTurn (const (pure ())) msgs specs
  , llmEmbed = \_ -> pure []
  , llmModels = pure
      [ ModelInfo (if T.null modelPath then "deepseek-flash" else modelPath)
                  "CPU recipe pipeline (local)"
                  524288
      ]
  , llmChatToolsStream = \msgs specs _gp onEvent -> do
      -- 回退：TRHA_RECIPE_STREAM=0 时不走流解析，样例文本直出纯文本
      off <- lookupEnv "TRHA_RECIPE_STREAM"
      if off == Just "0"
        then do
          let txt = cpuSampleText
          onEvent (ChunkDelta txt)
          pure ChatTurn { ctContent = txt, ctReasoning = Nothing
                        , ctReasoningSignature = Nothing, ctToolCalls = []
                        , ctUsage = Just (mkUsage 0 0 0), ctError = Nothing }
        else runCpuTurn onEvent msgs specs
  }

-- | 阻塞路径：非流式调用复用同管线（事件丢弃，取聚合结果）。
cpuBlocking :: [Message] -> IO [StreamChunk]
cpuBlocking msgs = do
  turn <- runCpuTurn (const (pure ())) (toChatMessages msgs) []
  pure ( [ChunkDelta (ctContent turn) | not (T.null (ctContent turn))]
      ++ maybe [] (\u -> [ChunkDone u]) (ctUsage turn)
      ++ maybe [] (\e -> [ChunkError e]) (ctError turn))
