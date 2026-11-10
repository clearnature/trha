-- | Live prefix-cache probe against the real DeepSeek API.
--
-- Skipped unless @DEEPSEEK_API_KEY@ is set: this spends tokens, so it is not
-- part of the default suite.
--
-- What it pins: a stable, append-only prefix must be served from the provider's
-- cache. The ratio is measured the way the bill sees it — cached prompt tokens
-- over all prompt tokens — because a hit rate that is not observable is a cost
-- that cannot be controlled.
{-# LANGUAGE OverloadedStrings #-}

module DeepSeekCacheSpec (deepSeekCacheSpec) where

import Control.Monad (forM)
import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (lookupEnv)
import Test.Hspec

import LLM.Adapter.Interface (LLMAdapter (..))
import LLM.Adapter.Types
import LLM.Providers.DeepSeek (createDeepSeekProvider)

-- | A large, byte-identical prefix. Size matters: with a prefix of @P@ tokens
-- and a turn of @t@ tokens, one request's hit ratio is about
-- @1 - t/(P+t)@, so 99% needs @P >= 100t@. The miss is not just the new turn —
-- the provider caches in 64-token blocks, so up to one block plus the turn is
-- always cold. ~25k tokens of prefix puts that below 0.5%.
stablePrefix :: Text
stablePrefix = T.unlines
  [ "第" <> T.pack (show i)
      <> "行：这是用于验证前缀缓存稳定性的固定文本，内容不重要，重要的是每次请求逐字节相同，"
      <> "并且长度足以跨过提供方的 64 token 缓存块边界。"
  | i <- [1 :: Int .. 1200] ]

deepSeekCacheSpec :: Spec
deepSeekCacheSpec = describe "DeepSeek prefix cache (live API)" $ do
  key <- runIO (lookupEnv "DEEPSEEK_API_KEY")
  case key of
    Nothing -> it "needs DEEPSEEK_API_KEY" $
      pendingWith "set DEEPSEEK_API_KEY to run the live provider probe"
    Just apiKey -> it "a stable append-only prefix stays above 99% cache hits" $ do
      adapter <- createDeepSeekProvider (T.pack apiKey)
      let turns = [ "第" <> T.pack (show i) <> "问：回答一个字：好" | i <- [1 :: Int .. 4] ]
      usages <- forM (zip [1 :: Int ..] turns) $ \(i, turn) -> do
        -- history is append-only: each request is the previous one plus one
        -- short user turn, so the provider can reuse everything but the tail
        let history = concat
              [ [ChatUser t, ChatAssistant "好" []]
              | t <- take (i - 1) turns ]
            msgs = ChatSystem stablePrefix : history ++ [ChatUser turn]
        turn' <- llmChatTools adapter msgs [] defaultGenParams
        pure $ case ctUsage turn' of
          -- 余额不足等账户状态错误走 ctError（HTTP 4xx 原文内联），无 usage
          -- 可言——这是账户状态，不是缓存判据失效，应跳过而不是把 live
          -- 探针记成失败。无 usage 且无账户错误仍算失败。
          _ | Just err <- ctError turn'
            , "Insufficient Balance" `T.isInfixOf` err ->
              Left "DeepSeek account has insufficient balance"
          Nothing -> Left "provider returned no usage (not a balance error)"
          Just u  -> Right (usageCacheHitTokens u, usageCacheMissTokens u + usageCacheHitTokens u)
      case [e | Left e <- usages] of
        (e : _) | e == "DeepSeek account has insufficient balance" -> pendingWith e
        (e : _) -> expectationFailure e
        [] -> pure ()
      let usageOf u = case u of
            Right p -> p
            Left e  -> error ("unreachable: skipped via pendingWith: " <> e)
          usages' = map usageOf usages

      let ratio (hit, total) = if total <= 0 then 0 else fromIntegral hit / fromIntegral total :: Double
          warm = drop 1 usages'
          aggregate = ratio (sum (map fst warm), sum (map snd warm))
          pct x = T.pack (show (fromIntegral (round (x * 10000) :: Int) / 100 :: Double)) <> "%"

      putStrLn $ "  per-request hit ratio: "
        <> T.unpack (T.intercalate " · "
             [ "req" <> T.pack (show i) <> "=" <> pct (ratio u)
             | (i, u) <- zip [1 :: Int ..] usages' ])
      putStrLn $ "  steady-state aggregate: " <> T.unpack (pct aggregate)

      -- The first request has nothing to hit; every later one must be ≥99%.
      mapM_ ((\u -> ratio u `shouldSatisfy` (>= 0.99)) . snd) (drop 1 (zip [1 :: Int ..] usages'))
      -- and the warm aggregate carries the headline claim
      aggregate `shouldSatisfy` (>= 0.99)
