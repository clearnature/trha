{-# LANGUAGE ForeignFunctionInterface #-}
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
-- 所有函数在 cdylib 未加载或未初始化时优雅降级（返回 @Nothing@），
-- 不抛异常——调用方决定是否回退到估算。
module LLM.Recipe.FFI
  ( recipeInit
  , recipeIsInit
  , recipeCountTokens
  , recipeRenderV41
  , recipeEncodeV41
  ) where

import Control.Monad (unless)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import Data.IORef
import Data.Maybe (isJust)
import Data.Maybe (fromMaybe)
import Foreign.C.String (CString, newCString, peekCString)
import Foreign.Ptr (nullPtr)
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
