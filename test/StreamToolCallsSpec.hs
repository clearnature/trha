{-# LANGUAGE OverloadedStrings #-}

-- | Parallel tool calls, end to end inside the kernel.
--
-- This is the bug that killed a real conversation: the kernel forwarded every
-- tool call with @index = 0@ and no id, so two parallel calls arrived at the
-- scheduler glued into one name ("todo_writerun_code") with an empty id. The
-- model then saw a malformed turn, repeated itself, and the loop stopped on the
-- repetition guard.
--
-- Two layers are pinned here:
--
--   * the stream accumulator keeps each call's index and provider id;
--   * the SSE the kernel writes carries both through, so clients can tell the
--     calls apart.
module StreamToolCallsSpec (streamToolCallsSpec) where

import Control.Monad (forM_)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.IORef
import Data.Foldable (toList)
import qualified Data.Aeson.KeyMap as KeyMap
import Test.Hspec

import Network.HTTP.Types (status200)
import Network.Wai (Application, responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)

import API.Server (toolCallDelta)
import qualified LLM.Stream as Stream
import LLM.Adapter.Types (ChatTurn (..), StreamChunk (..), ToolCall (..), Usage (..))

-- | One SSE frame, as an OpenAI-compatible provider writes it.
frame :: Value -> BL.ByteString
frame v = "data: " <> Aeson.encode v <> "\n\n"

delta :: Value -> Value
delta d = object [ "choices" .= [object ["index" .= (0 :: Int), "delta" .= d]] ]

-- | A provider that streams two parallel tool calls, then usage, then DONE.
twoCallStream :: BL.ByteString
twoCallStream = mconcat
  [ frame $ delta $ object
      [ "tool_calls" .= [ object
          [ "index" .= (0 :: Int), "id" .= ("call_a" :: String), "type" .= ("function" :: String)
          , "function" .= object [ "name" .= ("todo_write" :: String), "arguments" .= ("" :: String) ]
          ] ] ]
  , frame $ delta $ object
      [ "tool_calls" .= [ object
          [ "index" .= (0 :: Int)
          , "function" .= object [ "arguments" .= ("{\"todos\":[]}" :: String) ]
          ] ] ]
  , frame $ delta $ object
      [ "tool_calls" .= [ object
          [ "index" .= (1 :: Int), "id" .= ("call_b" :: String), "type" .= ("function" :: String)
          , "function" .= object
              [ "name" .= ("run_code" :: String), "arguments" .= ("{\"code\":\"1\"}" :: String) ]
          ] ] ]
  , frame $ object
      [ "usage" .= object
          [ "prompt_tokens" .= (120 :: Int), "completion_tokens" .= (7 :: Int)
          , "total_tokens" .= (127 :: Int)
          , "prompt_cache_hit_tokens" .= (96 :: Int), "prompt_cache_miss_tokens" .= (24 :: Int)
          ] ]
  , "data: [DONE]\n\n"
  ]

sseApp :: BL.ByteString -> Application
sseApp body _req respond =
  respond (responseLBS status200 [("Content-Type", "text/event-stream")] body)

streamToolCallsSpec :: Spec
streamToolCallsSpec = describe "parallel tool calls" $ do
  it "keeps each call's index and provider id while streaming" $
    testWithApplication (pure (sseApp twoCallStream)) $ \port -> do
      events <- newIORef ([] :: [StreamChunk])
      turn <- Stream.openAICompatStreamCall
        ("http://127.0.0.1:" <> show port <> "/v1/chat/completions")
        "test-key"
        (object ["model" .= ("test" :: String), "stream" .= True])
        (\c -> modifyIORef' events (c :))
      let calls = ctToolCalls turn
      length calls `shouldBe` 2
      map tcName calls `shouldBe` ["todo_write", "run_code"]
      map tcId calls `shouldBe` ["call_a", "call_b"]
      map tcArguments calls `shouldBe` ["{\"todos\":[]}", "{\"code\":\"1\"}"]
      -- usage, including the cache split, comes back on the same turn
      fmap usageCacheHitTokens (ctUsage turn) `shouldBe` Just 96
      fmap usageCacheMissTokens (ctUsage turn) `shouldBe` Just 24
      -- each call is announced once, with its own index
      got <- readIORef events
      let announced = [ i | ChunkToolCallAt i _ _ _ <- reverse got ]
      announced `shouldBe` [0, 1]
      forM_ [0 :: Int, 1] $ \i -> i `shouldSatisfy` (`elem` announced)

  it "builds a delta that carries index and the provider id" $ do
    let v = toolCallDelta 1 "call_b" "run_code" "{}"
        calls = case v of
          Aeson.Object o -> case KeyMap.lookup "tool_calls" o of
            Just (Aeson.Array a) -> toList a
            _                    -> []
          _ -> []
    case calls of
      [Aeson.Object c] -> do
        KeyMap.lookup "index" c `shouldBe` Just (Aeson.Number 1)
        KeyMap.lookup "id" c `shouldBe` Just (Aeson.String "call_b")
        KeyMap.lookup "type" c `shouldBe` Just (Aeson.String "function")
      other -> expectationFailure ("expected one tool call, got " <> show (length other))

  it "synthesizes an id for an unindexed call and keeps index 0" $ do
    let v = toolCallDelta 0 "" "bash" "{}"
        calls = case v of
          Aeson.Object o -> case KeyMap.lookup "tool_calls" o of
            Just (Aeson.Array a) -> toList a
            _                    -> []
          _ -> []
    case calls of
      [Aeson.Object c] -> do
        KeyMap.lookup "index" c `shouldBe` Just (Aeson.Number 0)
        KeyMap.lookup "id" c `shouldBe` Just (Aeson.String "call-0")
      other -> expectationFailure ("expected one tool call, got " <> show (length other))
