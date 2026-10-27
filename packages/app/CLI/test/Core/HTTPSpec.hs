{-# LANGUAGE OverloadedStrings #-}

-- | A dead backend must be an error value, not an exception.
--
-- Regression: @httpLbs@ throws 'HttpException'; the bridge did not catch it, so
-- `/new` on a machine where the scheduler was not running printed 25 lines of
-- http-client internals and exited 1 — the whole REPL died on the first
-- keystroke of a fresh install.
module Core.HTTPSpec (spec) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text as T
import Test.Hspec

import Core.HTTP
import Core.Types (CLIConfig(..), CLIError(..), defaultCLIConfig)

-- | Port 1 on loopback: nothing listens there, and connecting fails fast.
deadClient :: IO HTTPClient
deadClient = createHTTPClient "http" "127.0.0.1" 1 "dev-token" 3000 ""

spec :: Spec
spec = describe "HTTP errors" $ do
  it "reports an unreachable host as ConnectionError, not an exception" $ do
    client <- deadClient
    result <- httpGet client "/api/health" :: IO (Either CLIError ())
    case result of
      Left (ConnectionError message) -> do
        -- it has to say where it tried and what to start
        message `shouldSatisfy` T.isInfixOf "127.0.0.1:1"
        message `shouldSatisfy` T.isInfixOf "trha serve"
      other -> expectationFailure ("expected ConnectionError, got " <> show other)

  it "does the same for POST" $ do
    client <- deadClient
    result <- httpPost client "/api/session/start" ([] :: [Int]) :: IO (Either CLIError ())
    case result of
      Left (ConnectionError _) -> pure ()
      other -> expectationFailure ("expected ConnectionError, got " <> show other)

  describe "proxy policy" $ do
    it "keeps loopback targets direct whatever the setting says" $ do
      resolveProxy "127.0.0.1" "http://proxy:8080" `shouldBe` ProxyDirect
      resolveProxy "localhost" "none" `shouldBe` ProxyDirect
      resolveProxy "::1" "" `shouldBe` ProxyDirect
      resolveProxy "127.9.9.9" "http://proxy:8080" `shouldBe` ProxyDirect

    it "sends remote targets through the configured policy" $ do
      resolveProxy "api.deepseek.com" "" `shouldBe` ProxyFromEnv
      resolveProxy "api.deepseek.com" "none" `shouldBe` ProxyDirect
      resolveProxy "api.deepseek.com" "http://p.local:10808" `shouldBe` ProxyForced "p.local" 10808

    it "parses proxy URLs with and without the scheme" $ do
      parseProxyUrl "http://127.0.0.1:10808" `shouldBe` Just ("127.0.0.1", 10808)
      parseProxyUrl "proxy.lan:3128" `shouldBe` Just ("proxy.lan", 3128)
      parseProxyUrl "garbage" `shouldBe` Nothing
      parseProxyUrl "host:port" `shouldBe` Nothing

    it "classifies a refused connection as ConnectionError, not TimeoutError" $ do
      -- regression: `isTimeout` used a substring match on `show`, and the dumped
      -- Request record always contains `responseTimeout = ...`
      client <- deadClient
      result <- httpGet client "/api/health" :: IO (Either CLIError ())
      case result of
        Left TimeoutError -> expectationFailure "refused connection misclassified as timeout"
        Left (ConnectionError _) -> pure ()
        other -> expectationFailure ("expected ConnectionError, got " <> show other)

  describe "manager settings" $ do
    -- regression: the SSE subscriber built its own manager from
    -- `tlsManagerSettings`, so an https://localhost scheduler (self-signed by
    -- design) failed the handshake with "certificate has unknown CA" while
    -- every other request on the same client worked.
    it "recovers scheme and host from the base URL the bridge builds" $ do
      baseSchemeHost "https://localhost:3456" `shouldBe` Just ("https", "localhost")
      baseSchemeHost "http://127.0.0.1:3456" `shouldBe` Just ("http", "127.0.0.1")
      baseSchemeHost "https://api.example.com:443" `shouldBe` Just ("https", "api.example.com")
      baseSchemeHost "https://user@127.0.0.1:3456/api/x" `shouldBe` Just ("https", "127.0.0.1")
      baseSchemeHost "https://[::1]:3456" `shouldBe` Just ("https", "::1")

    it "fails closed when the base has no scheme" $ do
      baseSchemeHost "localhost:3456" `shouldBe` Nothing
      baseSchemeHost "" `shouldBe` Nothing

  describe "configProxy JSON compatibility" $ do
    it "defaults to the empty policy when reading an old settings file" $ do
      -- old files predate the key; the manual FromJSON must not reject them
      let oldObject = Aeson.object
            [ "configHost" Aeson..= ("localhost" :: T.Text)
            , "configPort" Aeson..= (3456 :: Int)
            , "configModel" Aeson..= ("m" :: T.Text)
            , "configMaxTokens" Aeson..= (1 :: Int)
            , "configTimeout" Aeson..= (1 :: Int)
            , "configRetries" Aeson..= (1 :: Int)
            , "configVerbose" Aeson..= False
            ]
      case (Aeson.fromJSON oldObject :: Aeson.Result CLIConfig) of
        Aeson.Success cfg -> configProxy cfg `shouldBe` ""
        Aeson.Error err -> expectationFailure ("old settings file failed to parse: " <> err)

    it "round-trips a configured proxy" $ do
      let cfg = defaultCLIConfig { configProxy = "http://proxy.lan:3128" }
      (Aeson.decode (Aeson.encode cfg) :: Maybe CLIConfig)
        `shouldBe` Just cfg
