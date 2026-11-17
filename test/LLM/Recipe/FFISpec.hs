{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

-- | FFI 绑定测试：trha-recipe-ffi cdylib 的行为验证。
--
-- 这些测试需要 cdylib (.so) 可加载 + tokenizer 文件可访问。若
-- LD_LIBRARY_PATH 未设或 .so 不存在，测试会优雅标记为 pending 而非失败
-- （纯函数/解析逻辑不受影响）。
module LLM.Recipe.FFISpec (spec) where

import Data.Maybe (isJust, isNothing)
import Test.Hspec

import LLM.Recipe.FFI
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Vector as V
import qualified Data.Text as T

-- | Skip helper：FFI 不可用时跳过所有依赖 .so 的测试。
requireFFI :: SpecWith () -> Spec
requireFFI = beforeAll_ recipeInit

spec :: Spec
spec = do
  describe "recipeIsInit" $
    it "首次调用 recipeInit 后为 True" $ do
      recipeInit
      recipeIsInit `shouldReturn` True

  describe "recipeCountTokens" $ requireFFI $ do
    it "短文本返回正整数" $ do
      r <- recipeCountTokens "hello world"
      r `shouldSatisfy` maybe False (> 0)

    it "空文本仍返回正数（对话渲染注入 BOS+框架 token）" $ do
      r <- recipeCountTokens ""
      r `shouldSatisfy` maybe False (> 0)

    it "长文本 token 数显著多于短文本" $ do
      short <- recipeCountTokens "hello"
      long  <- recipeCountTokens (T.replicate 100 "hello world ")
      case (short, long) of
        (Just s, Just l) -> l `shouldSatisfy` (> s * 5)
        _ -> fail "countTokens returned Nothing"

    it "中文文本返回正整数" $ do
      r <- recipeCountTokens "你好世界，这是一段中文测试。"
      r `shouldSatisfy` maybe False (> 0)

  describe "recipeRenderV41" $ requireFFI $ do
    let requestJson = "{\"model\":\"DeepSeek-V4.1-Flash\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"

    it "返回包含 User token 的 prompt" $ do
      r <- recipeRenderV41 requestJson
      case r of
        Just p  -> p `shouldSatisfy` T.isInfixOf "User"
        Nothing -> fail "renderV41 returned Nothing"

    it "prompt 以 BOS token 开头" $ do
      r <- recipeRenderV41 requestJson
      case r of
        Just p  -> p `shouldSatisfy` T.isPrefixOf "<｜begin▁of▁sentence｜>"
        Nothing -> fail "renderV41 returned Nothing"

    it "prompt 以 assistant 标记结尾（thinking 模式）" $ do
      r <- recipeRenderV41 requestJson
      case r of
        Just p  -> p `shouldSatisfy` T.isSuffixOf "<think>"
        Nothing -> fail "renderV41 returned Nothing"

    it "带工具定义的请求包含工具描述" $ do
      let withTools = "{\"model\":\"DeepSeek-V4.1-Flash\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"read\",\"description\":\"Read a file\",\"parameters\":{\"type\":\"object\"}}}]}"
      r <- recipeRenderV41 withTools
      case r of
        Just p  -> p `shouldSatisfy` T.isInfixOf "Read a file"
        Nothing -> fail "renderV41 returned Nothing"

  describe "recipeEncodeV41" $ requireFFI $ do
    let requestJson = "{\"model\":\"DeepSeek-V4.1-Flash\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"

    it "返回非空 token ID 列表" $ do
      r <- recipeEncodeV41 requestJson
      case r of
        Just ids -> ids `shouldSatisfy` not . null
        Nothing  -> fail "encodeV41 returned Nothing"

    it "token ID 都是非负整数（BOS=0 合法）" $ do
      r <- recipeEncodeV41 requestJson
      case r of
        Just ids -> mapM_ (\i -> i `shouldSatisfy` (>= 0)) ids
        Nothing  -> fail "encodeV41 returned Nothing"

  describe "优雅降级" $ do
    it "无效 JSON → renderV41 返回 Nothing（不抛异常）" $ do
      r <- recipeRenderV41 "not json at all"
      isNothing r `shouldBe` True

    it "无匹配的查询 → countTokens 仍返回值（tokenizer 不因文本内容失败）" $ do
      r <- recipeCountTokens "\0\x01\x02"
      isJust r `shouldBe` True

  -- ------------------------------------------------------------------
  -- dispatch 统一入口（trha-recipe-ffi ≥ 0.2 的全量能力面）
  -- ------------------------------------------------------------------
  let ccRequest = "{\"model\":\"DeepSeek-V4.1-Flash\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"

  describe "recipeDispatch / special_tokens" $
    it "列出 18 种特殊 token" $ do
      r <- recipeDispatch "special_tokens" "{}"
      fmap arrayFieldCount r `shouldBe` Just 18

  describe "recipeDispatch / convert" $ do
    it "cc 请求转换为 conversation JSON（含 user 消息）" $ do
      r <- recipeConvert "cc" ccRequest
      isJust r `shouldBe` True

    it "未知协议名 → Nothing（错误回传，不抛异常）" $ do
      r <- recipeConvert "wat" ccRequest
      isNothing r `shouldBe` True

  describe "recipeRender (dispatch)" $ do
    it "显式 v4 版本也能渲染出 prompt" $ do
      r <- recipeRender "cc" "v4" ccRequest
      case r of
        Just p  -> p `shouldSatisfy` not . T.null
        Nothing -> fail "render v4 returned Nothing"

    it "未知版本 → Nothing" $ do
      r <- recipeRender "cc" "v3" ccRequest
      isNothing r `shouldBe` True

  describe "recipeResolveLimits" $
    it "thinking 默认 max_tokens=65536" $ do
      r <- recipeResolveLimits "cc" ccRequest 100 1000000
      fmap fst r `shouldBe` Just 65536

  describe "recipeModelVersions" $
    it "dispatch 返回版本表（含 2 项）" $ do
      r <- recipeDispatch "model_versions" "{}"
      fmap arrayFieldCount r `shouldBe` Just 2

  -- ------------------------------------------------------------------
  -- 流会话（StreamProcessor 句柄化）
  -- ------------------------------------------------------------------
  describe "recipeStream* 会话" $ do
    let openStream = recipeStreamOpen "cc"
                       "{\"model\":\"DeepSeek-V4.1-Flash\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"thinking\":{\"type\":\"disabled\"}}"
                       Nothing "chatcmpl-hspec" "DeepSeek-V4.1-Flash"

    it "open 返回句柄" $ do
      h <- openStream
      isJust h `shouldBe` True

    it "ready chunk 产出 Start（role）协议块" $ do
      Just n <- openStream
      r <- recipeStreamFeed n "{\"type\":\"ready\",\"prompt_tokens\":12,\"prompt_cache_hit_tokens\":0}"
      fmap chunksCount r `shouldSatisfy` maybe False (> 0)
      _ <- recipeStreamAbort n
      pure ()

    it "text chunk 原样透传为 content 增量" $ do
      Just n <- openStream
      _ <- recipeStreamFeed n "{\"type\":\"ready\",\"prompt_tokens\":12,\"prompt_cache_hit_tokens\":0}"
      r <- recipeStreamFeed n "{\"type\":\"text\",\"content\":\"hello\",\"token_count\":2}"
      fmap deltaContents r `shouldBe` Just "hello"
      _ <- recipeStreamClose n Nothing
      pure ()

    it "close 后再 feed → Nothing（句柄已释放）" $ do
      Just n <- openStream
      _ <- recipeStreamClose n Nothing
      r <- recipeStreamFeed n "{\"type\":\"text\",\"content\":\"x\",\"token_count\":1}"
      isNothing r `shouldBe` True
  where
    -- 顶层 "special_tokens" / "model_versions" 数组长度（无 lens 的取法）
    arrayFieldCount (objAt "special_tokens" -> Just (Aeson.Array v)) = V.length v
    arrayFieldCount (objAt "model_versions" -> Just (Aeson.Array v)) = V.length v
    arrayFieldCount _ = 0

    objAt k (Aeson.Object o) = KM.lookup (AK.fromText k) o
    objAt _ _                = Nothing

    -- 响应里 chunks 数组的长度
    chunksCount (objAt "chunks" -> Just (Aeson.Array v)) = V.length v
    chunksCount _ = 0

    -- chunks[*].choices[0].delta.content 的拼接
    deltaContents v@(objAt "chunks" -> Just (Aeson.Array _)) =
      T.concat (deltaOf =<< chunkList v)
      where
        chunkList (objAt "chunks" -> Just (Aeson.Array xs)) = V.toList xs
        chunkList _ = []
        deltaOf = \case
          Aeson.Object co
            | Just (Aeson.Array cs) <- KM.lookup "choices" co
            , Just (Aeson.Object c0) <- cs V.!? 0
            , Just (Aeson.Object d) <- KM.lookup "delta" c0
            , Just (Aeson.String s) <- KM.lookup "content" d -> [s]
          _ -> []
    deltaContents _ = ""
