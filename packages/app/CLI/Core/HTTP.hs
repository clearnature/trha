{-# LANGUAGE OverloadedStrings #-}

module Core.HTTP
  ( -- * HTTP Client
    HTTPClient(..)
  , createHTTPClient

    -- * Proxy policy
  , ProxyChoice(..)
  , resolveProxy
  , isLoopbackHost
  , parseProxyUrl

    -- * HTTP Methods
  , httpGet
  , httpPost
  , httpPut
  , httpDelete

    -- * Helpers
  , sendRequest
  , buildUrl
  , parseResponse
  ) where

import Core.Types
import Control.Exception (try)
import Control.Monad (guard)
import Data.Aeson
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (HeaderName)
import Network.HTTP.Types.Status

-- | HTTP client
data HTTPClient = HTTPClient
  { httpClientManager :: Manager
  , httpClientBase    :: String
  , httpClientToken   :: Text
  }

-- | Create a new HTTP client
createHTTPClient :: Text -> Int -> Text -> Int -> Text -> IO HTTPClient
createHTTPClient host port token timeoutMs proxySetting = do
  let base = tlsManagerSettings
        { managerResponseTimeout = responseTimeoutMicro (timeoutMs * 1000) }
      settings = case resolveProxy host proxySetting of
        ProxyDirect    -> managerSetProxy noProxy base
        ProxyFromEnv   -> base
        ProxyForced h p -> managerSetProxy (useProxy (Proxy (TE.encodeUtf8 h) p)) base
  manager <- newManager settings
  let baseUrl = "http://" ++ T.unpack host ++ ":" ++ show port
  return $ HTTPClient manager baseUrl token

--------------------------------------------------------------------------------
-- Proxy policy
--------------------------------------------------------------------------------

-- | Resolved proxy behaviour for one target host.
data ProxyChoice
  = ProxyDirect     -- ^ never use a proxy (loopback target, or \"none\")
  | ProxyFromEnv    -- ^ honour http_proxy/https_proxy (the http-client default)
  | ProxyForced Text Int -- ^ always use this proxy host/port
  deriving (Show, Eq)

-- | Resolve the proxy behaviour for @host@ under the configured policy.
--
-- Safety rule: loopback targets are /always/ contacted directly — a
-- machine-wide @http_proxy@ must not intercept local scheduler or local model
-- gateway traffic (it turned \"connection refused on 127.0.0.1:1\" into a 503
-- from the proxy and broke the dead-backend contract).
--
-- Remote targets follow @configProxy@:
--
--   * @\"\"@    — default: honour the environment (@ProxyFromEnv@);
--   * @none@   — never proxy (@ProxyDirect@);
--   * a URL (@http://host:port@ or @host:port@) — force that proxy.
resolveProxy :: Text -> Text -> ProxyChoice
resolveProxy host cfg
  | isLoopbackHost host = ProxyDirect
  | cfg' == "none"      = ProxyDirect
  | Just (h, p) <- parseProxyUrl cfg' = ProxyForced h p
  | otherwise           = ProxyFromEnv
  where cfg' = T.strip cfg

-- | Hosts that must never be proxied.
isLoopbackHost :: Text -> Bool
isLoopbackHost raw =
  h `elem` ["localhost", "::1", "::ffff:127.0.0.1"] || "127." `T.isPrefixOf` h
  where h = T.toLower (T.strip raw)

-- | Parse @host:port@ or @http://host:port@ into components.
parseProxyUrl :: Text -> Maybe (Text, Int)
parseProxyUrl raw0 = do
  let stripped = T.strip raw0
      noScheme = if "http://" `T.isPrefixOf` stripped
                   then T.drop (T.length ("http://" :: Text)) stripped
                   else stripped
      (h, rest) = T.breakOn ":" noScheme
  p <- T.stripPrefix ":" rest
  port <- readMaybe (T.unpack p)
  guard (not (T.null h))
  pure (h, port)
  where
    readMaybe s = case reads s of
      [(n, "")] -> Just n
      _         -> Nothing


-- | Authorization header for the orchestration token.
authHeader :: HTTPClient -> [(HeaderName, ByteString)]
authHeader client = case httpClientToken client of
  t | T.null t -> []
    | otherwise -> [("Authorization", "Bearer " <> TE.encodeUtf8 t)]

-- | Build URL from path
buildUrl :: HTTPClient -> String -> String
buildUrl client path = httpClientBase client ++ path

-- | Parse JSON response
parseResponse :: FromJSON a => Response BSL.ByteString -> Either CLIError a
parseResponse response
  | statusIsSuccessful (responseStatus response) =
      case decode (responseBody response) of
        Just value -> Right value
        Nothing -> Left $ ValidationError "Failed to parse JSON response"
  | otherwise =
      case statusCode (responseStatus response) of
        401 -> Left $ AuthenticationError "Unauthorized"
        403 -> Left $ AuthenticationError "Forbidden"
        404 -> Left $ ServerError "Not found"
        500 -> Left $ ServerError "Internal server error"
        _   -> Left $ ServerError $ T.pack $ "HTTP error: " ++ show (statusCode (responseStatus response))

-- | Where the caller pointed us, plus what to start when nothing answers.
--
-- A frontend must never die because a backend is down: @httpLbs@ throws, and
-- an uncaught 'HttpException' used to take the whole REPL/TUI with it (25
-- lines of http-client internals, exit 1). Every verb funnels through
-- 'sendRequest' so a dead scheduler is a normal error value.
unreachable :: HTTPClient -> Text
unreachable client =
  "连不上 " <> T.pack (httpClientBase client)
    <> "（调度层没在跑？起法：`trha serve` 起内核 :3333，"
    <> "`cd packages/scheduler && node dist/cli.js` 起调度层 :3456）"

-- | Run one request, mapping connection-level failures to 'CLIError'.
sendRequest :: HTTPClient -> IO (Response BSL.ByteString) -> IO (Either CLIError (Response BSL.ByteString))
sendRequest client act = do
  result <- try act :: IO (Either HttpException (Response BSL.ByteString))
  pure $ case result of
    Right response -> Right response
    Left exception
      | isTimeout exception -> Left TimeoutError
      | otherwise -> Left (ConnectionError (unreachable client))
  where
    -- Substring matching on `show` is wrong here: an HttpExceptionRequest dumps
    -- the whole Request record, whose `responseTimeout` field makes every
    -- exception match "Timeout" — a refused connection classified as a timeout.
    isTimeout :: HttpException -> Bool
    isTimeout (HttpExceptionRequest _ ResponseTimeout) = True
    isTimeout _                                       = False

-- | HTTP GET request
httpGet :: FromJSON a => HTTPClient -> String -> IO (Either CLIError a)
httpGet client path = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request { requestHeaders = authHeader client }
  result <- sendRequest client (httpLbs request' (httpClientManager client))
  return $ result >>= parseResponse

-- | HTTP POST request
httpPost :: (ToJSON a, FromJSON b) => HTTPClient -> String -> a -> IO (Either CLIError b)
httpPost client path body = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request
        { method = "POST"
        , requestBody = RequestBodyLBS (encode body)
        , requestHeaders = ("Content-Type", "application/json") : authHeader client
        }
  result <- sendRequest client (httpLbs request' (httpClientManager client))
  return $ result >>= parseResponse

-- | HTTP PUT request
httpPut :: (ToJSON a, FromJSON b) => HTTPClient -> String -> a -> IO (Either CLIError b)
httpPut client path body = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request
        { method = "PUT"
        , requestBody = RequestBodyLBS (encode body)
        , requestHeaders = ("Content-Type", "application/json") : authHeader client
        }
  result <- sendRequest client (httpLbs request' (httpClientManager client))
  return $ result >>= parseResponse

-- | HTTP DELETE request
httpDelete :: FromJSON a => HTTPClient -> String -> IO (Either CLIError a)
httpDelete client path = do
  let url = buildUrl client path
  request <- parseRequest url
  let request' = request { method = "DELETE", requestHeaders = authHeader client }
  result <- sendRequest client (httpLbs request' (httpClientManager client))
  return $ result >>= parseResponse