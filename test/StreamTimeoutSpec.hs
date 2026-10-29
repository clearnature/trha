{-# LANGUAGE OverloadedStrings #-}

-- | A stalled stream must not hang the step forever.
--
-- Both streaming entry points set @responseTimeoutNone@ (so a slow first token
-- is not cut off), which meant a provider that accepted the request and then
-- went silent held the agent loop open indefinitely. The read is now bounded by
-- @TRHA_STREAM_TIMEOUT_MS@ (default 20 s) and reports a timeout the caller can
-- surface.
module StreamTimeoutSpec (streamTimeoutSpec) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import Network.HTTP.Types (status200)
import Network.Wai (Application, responseStream)
import Network.Wai.Handler.Warp (testWithApplication)
import qualified Data.ByteString.Builder as Builder
import System.Environment (setEnv, unsetEnv)
import Test.Hspec

import qualified LLM.Stream as Stream
import LLM.Adapter.Types (ChatTurn (..), ToolCall)

-- | One frame, then nothing. The response never ends.
stallingApp :: Application
stallingApp _req respond =
  respond $ responseStream status200 [("Content-Type", "text/event-stream")] $ \write flush -> do
    write $ Builder.byteString "data: {\"choices\":[{\"delta\":{\"content\":\"tik\"}}]}\n\n"
    flush
    threadDelay 5000000   -- far longer than the test's timeout

-- | Eight frames, 100 ms apart: the stream lives ~800 ms, which is longer than
-- the 300 ms budget in the test. Under a *total* timeout this would be killed;
-- under the per-read idle timeout it must survive.
slowApp :: Application
slowApp _req respond =
  respond $ responseStream status200 [("Content-Type", "text/event-stream")] $ \write flush -> do
    forM_ [1 :: Int .. 8] $ \i -> do
      write $ Builder.string8 ("data: {\"choices\":[{\"delta\":{\"content\":\"t" <> show i <> "\"}}]}\n\n")
      flush
      threadDelay 100000
    write $ Builder.string8 "data: [DONE]\n\n"
    flush

streamTimeoutSpec :: Spec
streamTimeoutSpec = describe "stream timeouts" $ do
  it "keeps a slow but live stream instead of enforcing a total deadline" $ do
    setEnv "TRHA_STREAM_TIMEOUT_MS" "300"
    testWithApplication (pure slowApp) $ \port -> do
      turn <- Stream.openAICompatStreamCall
        ("http://127.0.0.1:" <> show port <> "/v1/chat/completions")
        [("Authorization", "Bearer k")]
        (object ["model" .= ("test" :: String), "stream" .= True])
        (\_ -> pure ())
      unsetEnv "TRHA_STREAM_TIMEOUT_MS"
      ctError turn `shouldBe` Nothing
      ctContent turn `shouldBe` "t1t2t3t4t5t6t7t8"

  it "abandons a silent stream and reports the timeout" $ do
    setEnv "TRHA_STREAM_TIMEOUT_MS" "300"
    testWithApplication (pure stallingApp) $ \port -> do
      turn <- Stream.openAICompatStreamCall
        ("http://127.0.0.1:" <> show port <> "/v1/chat/completions")
        [("Authorization", "Bearer k")]
        (object ["model" .= ("test" :: String), "stream" .= True])
        (\_ -> pure ())
      unsetEnv "TRHA_STREAM_TIMEOUT_MS"
      -- what arrived before the stall is kept; the failure is explicit
      ctContent turn `shouldBe` "tik"
      fmap (T.isInfixOf "timed out") (ctError turn) `shouldBe` Just True
      ctToolCalls turn `shouldBe` ([] :: [ToolCall])

  it "uses the 20 s default when the variable is unset or invalid" $ do
    unsetEnv "TRHA_STREAM_TIMEOUT_MS"
    Stream.streamTimeoutMs `shouldReturn` 20000
    setEnv "TRHA_STREAM_TIMEOUT_MS" "nonsense"
    Stream.streamTimeoutMs `shouldReturn` 20000
    unsetEnv "TRHA_STREAM_TIMEOUT_MS"
