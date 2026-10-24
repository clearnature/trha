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

streamTimeoutSpec :: Spec
streamTimeoutSpec = describe "stream timeouts" $ do
  it "abandons a silent stream and reports the timeout" $ do
    setEnv "TRHA_STREAM_TIMEOUT_MS" "300"
    testWithApplication (pure stallingApp) $ \port -> do
      turn <- Stream.openAICompatStreamCall
        ("http://127.0.0.1:" <> show port <> "/v1/chat/completions")
        "k"
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
