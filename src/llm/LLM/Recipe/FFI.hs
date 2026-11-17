{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | FFI 绑定：trha-recipe-ffi cdylib（deepseek-recipe 的 C ABI 薄壳）。
--
-- JSON-in/JSON-out 模式——C 层只传字符串指针，Rust 侧 serde_json /
-- Haskell 侧 Aeson 处理一切复杂结构。提供：
--
--   * 'recipeInit'        —— 加载 tokenizer（一次性，惰性）
--   * 'recipeCountTokens' —— 精确 token 计数（替换 estimateTokens 估算）
--   * 'recipeRenderV41'   —— Chat Completions JSON → DeepSeek V4.1 prompt
--   * 'recipeEncodeV41'   —— Chat Completions JSON → token IDs
--
-- 以及全量能力面的统一入口（trha-recipe-ffi ≥ 0.2 dispatch 模式）：
--
--   * 'recipeDispatch'    —— op + payload → Aeson Value（通用分发）
--   * 'recipeConvert'     —— 三协议请求 → Conversation JSON
--   * 'recipeRender'      —— 三协议请求 → V4/V4.1 prompt
--   * 'recipeResolveLimits' —— max_tokens / top_p 解析
--   * 'recipeSpecialTokens' —— 18 种特殊 token 及拼写
--   * 流会话：'recipeStreamOpen' / 'recipeStreamFeed' / 'recipeStreamClose'
--     / 'recipeStreamAbort' —— StreamProcessor 句柄化
--
-- 所有函数在 cdylib 未加载或未初始化时优雅降级（返回 @Nothing@），
-- 不抛异常——调用方决定是否回退到估算。
module LLM.Recipe.FFI
  ( -- 旧直连入口（kernel token-count 链路在用）
    recipeInit
  , recipeIsInit
  , recipeCountTokens
  , recipeRenderV41
  , recipeEncodeV41
    -- dispatch 统一入口（全量能力面）
  , recipeDispatch
  , recipeConvert
  , recipeRender
  , recipeEncodeDispatch
  , recipeCountText
  , recipeResolveLimits
  , recipeSpecialTokens
  , recipeModelVersions
    -- 流会话
  , recipeStreamOpen
  , recipeStreamFeed
  , recipeStreamClose
  , recipeStreamAbort
  ) where

import Control.Monad (unless)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import Data.IORef
import Data.Maybe (isJust)
import Data.Maybe (fromMaybe)
import Foreign.C.String (CString, newCString, peekCString)
import Foreign.C.Types (CULLong(..))
import Foreign.Ptr (nullPtr)
import Data.Word (Word)
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text.Encoding as TE
import qualified Data.Text as T
import Data.Text (Text)

-- | tokenizer.json 默认路径（vendored 副本，相对于 repo root）。
defaultTokenizerPath :: FilePath
defaultTokenizerPath = "3rdparty/trha-recipe/static/tokenizers/v41/tokenizer.json"

-- ---------------------------------------------------------------------------
-- 原始 C 绑定
-- ---------------------------------------------------------------------------

foreign import ccall "recipe_init"
  c_recipe_init :: CString -> IO CString

foreign import ccall "recipe_count_tokens"
  c_recipe_count_tokens :: CString -> IO CString

foreign import ccall "recipe_render_v41"
  c_recipe_render_v41 :: CString -> IO CString

foreign import ccall "recipe_encode_v41"
  c_recipe_encode_v41 :: CString -> IO CString

foreign import ccall "recipe_is_init"
  c_recipe_is_init :: IO Bool

foreign import ccall "recipe_dispatch"
  c_recipe_dispatch :: CString -> CString -> IO CString

foreign import ccall "recipe_stream_open"
  c_recipe_stream_open :: CString -> CString -> CString -> CString -> CString -> IO CString

foreign import ccall "recipe_stream_feed"
  c_recipe_stream_feed :: CULLong -> CString -> IO CString

foreign import ccall "recipe_stream_close"
  c_recipe_stream_close :: CULLong -> CString -> IO CString

foreign import ccall "recipe_stream_abort"
  c_recipe_stream_abort :: CULLong -> IO CString

foreign import ccall "recipe_free_string"
  c_recipe_free_string :: CString -> IO ()

-- ---------------------------------------------------------------------------
-- 内部工具
-- ---------------------------------------------------------------------------

-- | Haskell Text → CString（UTF-8 编码）。
toCS :: Text -> IO CString
toCS = newCString . T.unpack

-- | 调 C 函数 → 取 JSON 回复指针 → 解析 → 释放。
callAndParse :: (CString -> IO CString) -> Text -> IO (Maybe Aeson.Value)
callAndParse fn payload = do
  cInput <- toCS payload
  resultPtr <- fn cInput
  if resultPtr == nullPtr
    then pure Nothing
    else do
      -- 读原始字节（不经过 locale 解码），Aeson 直接解析 UTF-8 JSON
      rawBytes <- BS.packCString resultPtr
      c_recipe_free_string resultPtr
      let decoded = Aeson.decode (BSL.fromStrict rawBytes) :: Maybe Aeson.Value
      pure decoded

-- | 从 Aeson Object 提取字段（避免额外 FromJSON 约束）。
getField :: Aeson.FromJSON a => Aeson.Object -> Text -> Maybe a
getField o key = case KM.lookup (AK.fromText key) o of
  Just v -> case Aeson.fromJSON v of
    Aeson.Success a -> Just a
    _               -> Nothing
  Nothing -> Nothing

-- | 确保已初始化（幂等：首次调用时用默认路径加载 tokenizer）。
ensureInit :: IO ()
ensureInit = do
  initialised <- c_recipe_is_init
  unless initialised $ do
    pathCS <- toCS (T.pack defaultTokenizerPath)
    resultPtr <- c_recipe_init pathCS
    c_recipe_free_string resultPtr

-- ---------------------------------------------------------------------------
-- 公开 API
-- ---------------------------------------------------------------------------

-- | 初始化 tokenizer（幂等——重复调用只生效一次）。
recipeInit :: IO ()
recipeInit = ensureInit

-- | 是否已初始化。
recipeIsInit :: IO Bool
recipeIsInit = c_recipe_is_init

-- | 精确 token 计数：纯文本 → tokenizer 编码 → token 数。
-- 未初始化或错误时返回 @Nothing@（调用方可回退估算）。
recipeCountTokens :: Text -> IO (Maybe Int)
recipeCountTokens text = do
  ensureInit
  callAndParse c_recipe_count_tokens text >>= \v ->
    pure (v >>= getField' "count")
  where
    getField' :: Aeson.FromJSON a => Text -> Aeson.Value -> Maybe a
    getField' k (Aeson.Object o) = getField o k
    getField' _ _                = Nothing

-- | Chat Completions JSON → DeepSeek V4.1 prompt 渲染。
-- 输入为标准 OpenAI 格式的 JSON 文本；返回 prompt 字符串。
-- 未初始化或错误时返回 @Nothing@。
recipeRenderV41 :: Text -> IO (Maybe Text)
recipeRenderV41 requestJson = do
  ensureInit
  callAndParse c_recipe_render_v41 requestJson >>= \v ->
    pure (v >>= getField' "prompt")
  where
    getField' :: Aeson.FromJSON a => Text -> Aeson.Value -> Maybe a
    getField' k (Aeson.Object o) = getField o k
    getField' _ _                = Nothing

-- | Chat Completions JSON → token IDs 编码。
-- 返回 token ID 列表；未初始化或错误时返回 @Nothing@。
recipeEncodeV41 :: Text -> IO (Maybe [Int])
recipeEncodeV41 requestJson = do
  ensureInit
  callAndParse c_recipe_encode_v41 requestJson >>= \v ->
    pure (v >>= getField' "token_ids")
  where
    getField' :: Aeson.FromJSON a => Text -> Aeson.Value -> Maybe a
    getField' k (Aeson.Object o) = getField o k
    getField' _ _                = Nothing

-- ---------------------------------------------------------------------------
-- dispatch 统一入口（trha-recipe-ffi ≥ 0.2）
-- ---------------------------------------------------------------------------

-- | 通用分发：op + payload（JSON 文本）→ 解析后的 Aeson Value。
-- 返回 @Nothing@ 表示 cdylib 未加载；错误以 @[error]@ 字段回传。
recipeDispatch :: Text -> Text -> IO (Maybe Aeson.Value)
recipeDispatch op payload = do
  cOp <- toCS op
  cPayload <- toCS payload
  resultPtr <- c_recipe_dispatch cOp cPayload
  if resultPtr == nullPtr
    then pure Nothing
    else do
      rawBytes <- BS.packCString resultPtr
      c_recipe_free_string resultPtr
      pure (Aeson.decode (BSL.fromStrict rawBytes))

-- | dispatch 的类型化壳：取 @[key]@ 字段（错误时 @Nothing@）。
dispatchField :: Aeson.FromJSON a => Text -> Text -> Text -> IO (Maybe a)
dispatchField op payload key = do
  recipeDispatch op payload >>= \case
    Just (Aeson.Object o) -> pure (getField o key)
    _                     -> pure Nothing

-- | 三协议请求 → Conversation JSON（@kind@：@cc@/@responses@/@anthropic@）。
-- 返回 @conversation@ 对象原文；失败回 @Nothing@。
recipeConvert :: Text -> Text -> IO (Maybe Aeson.Value)
recipeConvert kind requestJson = do
  let payload = Aeson.encode (Aeson.object ["kind" Aeson..= kind, "request" Aeson..= requestJsonText requestJson])
  dispatchField "convert" (babel payload) "conversation"

-- | 三协议请求 → V4（@v4@）或 V4.1（@v41@）prompt 渲染。
recipeRender :: Text -> Text -> Text -> IO (Maybe Text)
recipeRender kind version requestJson = do
  ensureInit
  let payload = Aeson.encode (Aeson.object
        ["kind" Aeson..= kind, "version" Aeson..= version, "request" Aeson..= requestJsonText requestJson])
  dispatchField "render" (babel payload) "prompt"

-- | 三协议请求 → V4/V4.1 token IDs。
recipeEncodeDispatch :: Text -> Text -> Text -> IO (Maybe [Int])
recipeEncodeDispatch kind version requestJson = do
  ensureInit
  let payload = Aeson.encode (Aeson.object
        ["kind" Aeson..= kind, "version" Aeson..= version, "request" Aeson..= requestJsonText requestJson])
  dispatchField "encode" (babel payload) "token_ids"

-- | 纯文本精确计数（dispatch 路径；与 'recipeCountTokens' 等价）。
recipeCountText :: Text -> IO (Maybe Int)
recipeCountText text = do
  ensureInit
  let payload = Aeson.encode (Aeson.object ["text" Aeson..= text])
  dispatchField "count_text" (babel payload) "count"

-- | 推理限额解析：@max_tokens@（默认值按思考模式）+ @top_p@。
recipeResolveLimits :: Text -> Text -> Int -> Int -> IO (Maybe (Int, Double))
recipeResolveLimits kind requestJson promptTokens contextLimit = do
  let payload = Aeson.encode (Aeson.object
        [ "kind" Aeson..= kind
        , "request" Aeson..= requestJsonText requestJson
        , "prompt_tokens" Aeson..= promptTokens
        , "context_limit" Aeson..= contextLimit
        ])
  recipeDispatch "resolve_limits" (babel payload) >>= \case
    Just (Aeson.Object o) -> do
      let mt = getField o "max_tokens" :: Maybe Int
          tp = getField o "top_p" :: Maybe Double
      pure (case (mt, tp) of
        (Just a, Just b) -> Just (a, b)
        _                -> Nothing)
    _ -> pure Nothing

-- | 18 种特殊 token 及默认拼写：@[{name, spelling}]@。
recipeSpecialTokens :: IO (Maybe Aeson.Value)
recipeSpecialTokens = dispatchField "special_tokens" "{}" "special_tokens"

-- | 支持的模型版本表（@DeepseekV4Pro@ / @DeepseekV41Flash@）。
recipeModelVersions :: IO (Maybe Aeson.Value)
recipeModelVersions = dispatchField "model_versions" "{}" "model_versions"

-- | payload 里 request 既可内嵌对象也可内嵌字符串——统一为字符串，
-- Rust 侧按 JSON 文本解析。
requestJsonText :: Text -> Aeson.Value
requestJsonText = Aeson.String

-- | BSL.ByteString → Text 载体（Aeson.encode 产出 lazy BS）。
babel :: BSL.ByteString -> Text
babel = TE.decodeUtf8 . BSL.toStrict

-- ---------------------------------------------------------------------------
-- 流会话（StreamProcessor 句柄化）
-- ---------------------------------------------------------------------------

-- | 开流：协议 @kind@ + 请求 JSON + 可选 tokenizer 路径。
-- 返回句柄；失败回 @Nothing@（@[error]@ 在响应里）。
recipeStreamOpen :: Text -> Text -> Maybe FilePath -> Text -> Text -> IO (Maybe Word)
recipeStreamOpen kind requestJson mTokPath responseId model = do
  cKind <- toCS kind
  cReq <- toCS requestJson
  cTok <- case mTokPath of
    Just p  -> newCString p
    Nothing -> pure nullPtr
  cRid <- toCS responseId
  cModel <- toCS model
  resultPtr <- c_recipe_stream_open cKind cReq cTok cRid cModel
  readHandleReply resultPtr

-- | 喂一个推理块（@ready@/@text@/@tokens@/@finish@ JSON），
-- 返回已就绪的协议 chunk 数组原文；失败回 @Nothing@。
recipeStreamFeed :: Word -> Text -> IO (Maybe Aeson.Value)
recipeStreamFeed handle chunkJson =
  withStreamHandle handle $ \h -> do
    cChunk <- toCS chunkJson
    resultPtr <- c_recipe_stream_feed h cChunk
    readValueReply resultPtr

-- | 收流：发 Finish、等管道冲刷，返回剩余 chunk（含 finish/usage）。
recipeStreamClose :: Word -> Maybe Text -> IO (Maybe Aeson.Value)
recipeStreamClose handle mReason =
  withStreamHandle handle $ \h -> do
    cReason <- case mReason of
      Just r  -> toCS r
      Nothing -> pure nullPtr
    resultPtr <- c_recipe_stream_close h cReason
    readValueReply resultPtr

-- | 弃流：abort 管道、按序释放句柄。
recipeStreamAbort :: Word -> IO (Maybe Aeson.Value)
recipeStreamAbort handle =
  withStreamHandle handle $ \h -> do
    resultPtr <- c_recipe_stream_abort h
    readValueReply resultPtr

-- | Word → CULLong 的句柄桥。
withStreamHandle :: Word -> (CULLong -> IO a) -> IO a
withStreamHandle h f = f (CULLong (fromIntegral h))

-- | 流 open 的 @[handle]@ 字段提取。
readHandleReply :: CString -> IO (Maybe Word)
readHandleReply resultPtr = do
  mv <- readValueReply resultPtr
  pure $ case mv of
    Just (Aeson.Object o) -> fromIntegral <$> (getField o "handle" :: Maybe Int)
    _                     -> Nothing

-- | 读响应指针 → Aeson Value（原始字节，不走 locale）→ 释放。
-- 响应里带 @[error]@ 字段按失败处理（回 @Nothing@），与「错误不抛异常、
-- 失败回 Nothing」的模块约定一致。
readValueReply :: CString -> IO (Maybe Aeson.Value)
readValueReply resultPtr
  | resultPtr == nullPtr = pure Nothing
  | otherwise = do
      rawBytes <- BS.packCString resultPtr
      c_recipe_free_string resultPtr
      pure $ case Aeson.decode (BSL.fromStrict rawBytes) of
        Just (Aeson.Object o) | KM.member (AK.fromText "error") o -> Nothing
        v                                                         -> v
