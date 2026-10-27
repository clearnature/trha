{-# LANGUAGE OverloadedStrings #-}

-- | The kernel loopback gate: binding to 127.0.0.1 alone does not stop a
-- browser page or another local process, so these check the four rules that
-- do (Host, Origin, JSON-only writes, Bearer token).
module SecuritySpec (securitySpec) where

import qualified Data.ByteString.Char8 as BC
import Control.Exception (IOException, try)
import Network.HTTP.Types (status401, status403, status415)
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import Test.Hspec

import API.Security

token :: BC.ByteString
token = "s3cret-token"

-- | A well-formed request: loopback Host, JSON, valid Bearer.
ok :: BC.ByteString -> BC.ByteString -> RequestFacts
ok method path = RequestFacts
  { rfMethod = method
  , rfPath = path
  , rfHost = Just "127.0.0.1:19433"
  , rfOrigin = Nothing
  , rfContentType = Just "application/json"
  , rfAuth = Just "Bearer s3cret-token"
  }

securitySpec :: Spec
securitySpec = describe "API.Security loopback gate" $ do
  it "lets a well-formed loopback request through" $
    decide token (ok "POST" "/agent/step") `shouldBe` Allow

  it "exempts GET /health so the scheduler can probe a starting kernel" $
    decide token (ok "GET" "/health") `shouldBe` Allow

  it "refuses a request addressed to another host (DNS rebinding)" $
    decide token (ok "GET" "/v1/models") { rfHost = Just "evil.example" }
      `shouldBe` Refuse status403 "loopback.host_rejected"

  it "accepts IPv6 loopback hosts" $
    decide token (ok "GET" "/v1/models") { rfHost = Just "[::1]:19433" }
      `shouldBe` Allow

  it "refuses a cross-origin browser request" $
    decide token (ok "POST" "/agent/step") { rfOrigin = Just "https://evil.example" }
      `shouldBe` Refuse status403 "loopback.origin_rejected"

  it "accepts a same-origin browser request" $
    decide token (ok "POST" "/agent/step") { rfOrigin = Just "http://127.0.0.1:19433" }
      `shouldBe` Allow

  it "refuses a non-JSON write (CSRF simple request)" $
    decide token (ok "POST" "/agent/step") { rfContentType = Just "text/plain" }
      `shouldBe` Refuse status415 "content-type.not_json"

  it "does not require JSON on reads" $
    decide token (ok "GET" "/v1/models") { rfContentType = Nothing }
      `shouldBe` Allow

  it "refuses a missing token" $
    decide token (ok "POST" "/agent/step") { rfAuth = Nothing }
      `shouldBe` Refuse status401 "loopback.unauthorized"

  it "refuses a wrong token" $
    decide token (ok "POST" "/agent/step") { rfAuth = Just "Bearer wrong" }
      `shouldBe` Refuse status401 "loopback.unauthorized"

  it "refuses a non-Bearer scheme" $
    decide token (ok "POST" "/agent/step") { rfAuth = Just "Basic s3cret-token" }
      `shouldBe` Refuse status401 "loopback.unauthorized"

  it "accepts a case-insensitive bearer scheme with a JSON charset" $ do
    decide token (ok "POST" "/agent/step")
      { rfAuth = Just "bearer s3cret-token"
      , rfContentType = Just "application/json; charset=utf-8"
      } `shouldBe` Allow

  describe "per-launch token" $ do
    it "rotates on every launch and publishes atomically" $ do
      tmp <- getTemporaryDirectory
      let path = tmp </> "trha-security-spec-token"
      _ <- try (removeFile path) :: IO (Either IOException ())
      first <- rotateTokenAt path
      second <- rotateTokenAt path
      first `shouldNotBe` second
      BC.length first `shouldBe` 64
      BC.length second `shouldBe` 64
      -- the file holds the latest token; no temp file is left behind
      BC.readFile path `shouldReturn` second
      doesFileExist (path ++ ".tmp") `shouldReturn` False
