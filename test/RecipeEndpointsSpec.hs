-- | deepseek-recipe 能力面的 HTTP 契约（W1）。
--
-- 四个 /api/recipe/* 端点是 FFI 能力面唯一的出网形态；这里钉住的是
-- **HTTP 层语义**而非库语义（库语义由 Rust 侧 22 例与 FFISpec 钉死）：
--
--   * op 固定于路由，payload 白名单字段（裸分发面不出网）
--   * 库报错 → 400 带错误文本；cdylib 不可载 → 503
--   * encode 的 token_ids 默认省略（ids opt-in）——50 万 token 的响应
--     不该默认全量回传
--
-- 需要 .so 可加载 + tokenizer 可访问；机器上缺失时这些测试会失败而非
-- 跳过（端点存在性本身就是契约）。
{-# LANGUAGE OverloadedStrings #-}

module RecipeEndpointsSpec (recipeEndpointsSpec) where

import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text.Encoding as TE
import Data.List (isInfixOf)
import qualified Data.Text as T
import Network.HTTP.Client
import Network.HTTP.Types (statusCode)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import Test.Hspec

import API.Server (mkStubApp)

ccRequest :: Value
ccRequest = object
  [ "model" .= ("DeepSeek-V4.1-Flash" :: T.Text)
  , "messages" .= [ object [ "role" .= ("user" :: T.Text), "content" .= ("hi" :: T.Text) ] ]
  ]

recipeEndpointsSpec :: Spec
recipeEndpointsSpec =
  -- mkStubApp 与 recipe 端点互不依赖（端点不碰 adapter/state dir）；
  -- 借它的 mkApp 装配拿到完整路由表。
  beforeAll (mkStubApp Nothing) $
  describe "POST /api/recipe/* (deepseek-recipe 能力面)" $ do
    let withApp :: Application -> (Manager -> String -> IO a) -> IO a
        withApp app act =
          testWithApplication (pure app) $ \port -> do
            mgr <- newManager defaultManagerSettings
            act mgr ("http://127.0.0.1:" ++ show port)

        httpPost :: Manager -> String -> Value -> IO (Int, String)
        httpPost mgr url body = do
          req0 <- parseRequest ("POST " ++ url)
          let req = req0 { method         = "POST"
                         , requestBody    = RequestBodyLBS (encode body)
                         , requestHeaders = [("Content-Type", "application/json")]
                         }
          res <- httpLbs req mgr
          pure ( statusCode (responseStatus res)
               , T.unpack (TE.decodeUtf8 (BLC.toStrict (responseBody res))) )

    it "render：prompt 以 BOS 开头（HTTP 直调 = FFISpec 同语义）" $ \app -> withApp app $ \mgr base -> do
      (c, body) <- httpPost mgr (base ++ "/api/recipe/render") $ object
        [ "kind" .= ("cc" :: T.Text), "request" .= ccRequest ]
      c `shouldBe` 200
      body `shouldSatisfy` ("<｜begin▁of▁sentence｜>" `isInfixOf`)

    it "encode：默认只回 count，ids=true 才回 token_ids" $ \app -> withApp app $ \mgr base -> do
      (c, body) <- httpPost mgr (base ++ "/api/recipe/encode") $ object
        [ "kind" .= ("cc" :: T.Text), "request" .= ccRequest ]
      c `shouldBe` 200
      body `shouldSatisfy` ("\"count\":" `isInfixOf`)
      body `shouldSatisfy` (not . ("token_ids" `isInfixOf`))

      (c2, body2) <- httpPost mgr (base ++ "/api/recipe/encode") $ object
        [ "kind" .= ("cc" :: T.Text), "request" .= ccRequest, "ids" .= True ]
      c2 `shouldBe` 200
      body2 `shouldSatisfy` ("token_ids" `isInfixOf`)

    it "convert：conversation 含 user 消息与 thinking_mode" $ \app -> withApp app $ \mgr base -> do
      (c, body) <- httpPost mgr (base ++ "/api/recipe/convert") $ object
        [ "kind" .= ("cc" :: T.Text), "request" .= ccRequest ]
      c `shouldBe` 200
      body `shouldSatisfy` ("\"conversation\":" `isInfixOf`)
      body `shouldSatisfy` ("\"thinking_mode\":true" `isInfixOf`)

    it "limits：thinking 默认 max_tokens=65536" $ \app -> withApp app $ \mgr base -> do
      (c, body) <- httpPost mgr (base ++ "/api/recipe/limits") $ object
        [ "kind" .= ("cc" :: T.Text)
        , "request" .= ccRequest
        , "prompt_tokens" .= (100 :: Int)
        , "context_limit" .= (1000000 :: Int)
        ]
      c `shouldBe` 200
      body `shouldSatisfy` ("\"max_tokens\":65536" `isInfixOf`)

    it "trha 别名归一：deepseek-flash → DeepSeek-V4.1-Flash（encode 可用）" $ \app -> withApp app $ \mgr base -> do
      (c, body) <- httpPost mgr (base ++ "/api/recipe/encode") $ object
        [ "kind" .= ("cc" :: T.Text)
        , "request" .= object
            [ "model" .= ("deepseek-flash" :: T.Text)
            , "messages" .= [ object [ "role" .= ("user" :: T.Text), "content" .= ("hi" :: T.Text) ] ]
            ]
        ]
      c `shouldBe` 200
      body `shouldSatisfy` ("\"count\":" `isInfixOf`)
      body `shouldSatisfy` ("DeepseekV41Flash" `isInfixOf`)

    it "image/resolve：1×1 PNG data_url → image_count=1 + total_tokens>0" $ \app -> withApp app $ \mgr base -> do
      let pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC" :: T.Text
      (c, body) <- httpPost mgr (base ++ "/api/recipe/image/resolve") $ object
        [ "sources" .= [ object
            [ "kind" .= ("data_url" :: T.Text)
            , "data_url" .= ("data:image/png;base64," <> pngB64)
            , "path" .= ("red.png" :: T.Text)
            ] ]
        ]
      c `shouldBe` 200
      body `shouldSatisfy` ("\"image_count\":1" `isInfixOf`)
      body `shouldSatisfy` ("\"total_tokens\":" `isInfixOf`)

    it "image/token-spec：1024×768 → token ≤ 1024 上限" $ \app -> withApp app $ \mgr base -> do
      (c, body) <- httpPost mgr (base ++ "/api/recipe/image/token-spec") $ object
        [ "width" .= (1024 :: Int), "height" .= (768 :: Int) ]
      c `shouldBe` 200
      body `shouldSatisfy` ("\"token_count\":" `isInfixOf`)
      body `shouldSatisfy` ("\"max_token_count\":1024" `isInfixOf`)

    it "image/resolve：坏字节 → 400 带错误文本" $ \app -> withApp app $ \mgr base -> do
      (c, body) <- httpPost mgr (base ++ "/api/recipe/image/resolve") $ object
        [ "sources" .= [ object
            [ "kind" .= ("bytes" :: T.Text)
            , "base64" .= ("bm90LWFuLWltYWdl" :: T.Text)   -- "not-an-image"
            ] ]
        ]
      c `shouldBe` 400
      body `shouldSatisfy` ("unsupported image" `isInfixOf`)

    it "未知 kind → 400 带错误文本（不是 500）" $ \app -> withApp app $ \mgr base -> do
      (c, body) <- httpPost mgr (base ++ "/api/recipe/convert") $ object
        [ "kind" .= ("wat" :: T.Text), "request" .= ccRequest ]
      c `shouldBe` 400
      body `shouldSatisfy` ("unknown protocol kind" `isInfixOf`)
