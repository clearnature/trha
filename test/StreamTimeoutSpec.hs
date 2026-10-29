{-# LANGUAGE OverloadedStrings #-}

-- | A stalled stream must not hang the step forever.
--
-- Both streaming entry points set @responseTimeoutNone@ (so a slow first token
-- is not cut off), which meant a provider that accepted the request and then
-- went silent held the agent loop open indefinitely. Reads are now bounded by
-- two budgets: @TRHA_STREAM_TIMEOUT_MS@ (default 45 s) for silence *after* the
-- first byte, and @TRHA_STREAM_FIRST_BYTE_TIMEOUT_MS@ (default 90 s) for the
-- wait before it — large contexts spend most of that wait in provider queuing
-- and prompt processing, not in a dead connection.
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

endpoint :: Int -> String
endpoint port = "http://127.0.0.1:" <> show port <> "/v1/chat/completions"

call :: Int -> IO ChatTurn
call port = Stream.openAICompatStreamCall
  (endpoint port)
  [("Authorization", "Bearer k")]
  (object ["model" .= ("test" :: String), "stream" .= True])
  (\_ -> pure ())

clearBudgets :: IO ()
clearBudgets = do
  unsetEnv "TRHA_STREAM_TIMEOUT_MS"
  unsetEnv "TRHA_STREAM_FIRST_BYTE_TIMEOUT_MS"

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

-- | 1 s of silence before the first byte, then a complete answer. Under the
-- old single budget (used for the first read too) this looked like a dead
-- provider; with a separate first-byte budget it is just a slow start.
slowFirstByteApp :: Application
slowFirstByteApp _req respond =
  respond $ responseStream status200 [("Content-Type", "text/event-stream")] $ \write flush -> do
    threadDelay 1000000
    write $ Builder.string8 "data: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}\n\n"
    flush
    write $ Builder.string8 "data: [DONE]\n\n"
    flush

-- | Never sends anything: only the first-byte budget can catch this.
silentApp :: Application
silentApp _req respond =
  respond $ responseStream status200 [("Content-Type", "text/event-stream")] $ \write flush -> do
    threadDelay 5000000
    write $ Builder.string8 "data: [DONE]\n\n"
    flush

streamTimeoutSpec :: Spec
streamTimeoutSpec = describe "stream timeouts" $ do
  it "keeps a slow but live stream instead of enforcing a total deadline" $ do
    setEnv "TRHA_STREAM_TIMEOUT_MS" "300"
    testWithApplication (pure slowApp) $ \port -> do
      turn <- call port
      clearBudgets
      ctError turn `shouldBe` Nothing
      ctContent turn `shouldBe` "t1t2t3t4t5t6t7t8"

  it "abandons a silent mid-stream and reports the idle timeout" $ do
    setEnv "TRHA_STREAM_TIMEOUT_MS" "300"
    testWithApplication (pure stallingApp) $ \port -> do
      turn <- call port
      clearBudgets
      -- what arrived before the stall is kept; the failure is explicit
      ctContent turn `shouldBe` "tik"
      fmap (T.isInfixOf "mid-stream") (ctError turn) `shouldBe` Just True
      ctToolCalls turn `shouldBe` ([] :: [ToolCall])

  it "waits out a slow first byte with the larger first-byte budget" $ do
    setEnv "TRHA_STREAM_TIMEOUT_MS" "200"
    setEnv "TRHA_STREAM_FIRST_BYTE_TIMEOUT_MS" "5000"
    testWithApplication (pure slowFirstByteApp) $ \port -> do
      turn <- call port
      clearBudgets
      ctError turn `shouldBe` Nothing
      ctContent turn `shouldBe` "late"

  it "reports a first-byte timeout separately from mid-stream silence" $ do
    setEnv "TRHA_STREAM_TIMEOUT_MS" "5000"
    setEnv "TRHA_STREAM_FIRST_BYTE_TIMEOUT_MS" "200"
    testWithApplication (pure silentApp) $ \port -> do
      turn <- call port
      clearBudgets
      ctContent turn `shouldBe` ""
      fmap (T.isInfixOf "no first byte") (ctError turn) `shouldBe` Just True

  it "uses the documented defaults when the variables are unset or invalid" $ do
    clearBudgets
    Stream.streamTimeoutMs `shouldReturn` 45000
    Stream.streamFirstByteTimeoutMs `shouldReturn` 90000
    setEnv "TRHA_STREAM_TIMEOUT_MS" "nonsense"
    setEnv "TRHA_STREAM_FIRST_BYTE_TIMEOUT_MS" "0"
    Stream.streamTimeoutMs `shouldReturn` 45000
    Stream.streamFirstByteTimeoutMs `shouldReturn` 90000
    clearBudgets
