{-# LANGUAGE OverloadedStrings #-}

-- | Proxy policy for kernel outbound HTTP (model providers, probes).
--
-- Safety rule: loopback targets (local model gateways such as ollama/one-api
-- on @127.0.0.1@) are /always/ contacted directly — a machine-wide
-- @http_proxy@ must not intercept them.  Remote targets follow @TRHA_PROXY@:
-- unset means the http-client default (honour the environment), @none@ means
-- never proxy, otherwise @http://host:port@ forces that proxy.
module Core.HTTPProxy
  ( isLoopbackHost
  , parseProxySpec
  , ProxyChoice(..)
  , resolveProxyChoice
  , proxyAwareSettings
  ) where

import qualified Data.ByteString.Char8 as BS8
import Data.Char (toLower)
import Data.List (isPrefixOf)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import System.Environment (lookupEnv)

-- | Hosts that must never be proxied.
isLoopbackHost :: String -> Bool
isLoopbackHost raw0 =
  h `elem` ["localhost", "::1", "::ffff:127.0.0.1"] || "127." `isPrefixOf` h
  where h = map toLower (trim raw0)

trim :: String -> String
trim = f . f
  where f = reverse . dropWhile (== ' ')

-- | Parse @host:port@ or @http://host:port@ into components.
parseProxySpec :: String -> Maybe (String, Int)
parseProxySpec raw0 = do
  let noScheme = if "http://" `isPrefixOf` s then drop 7 s else s
      (h, rest) = span (/= ':') noScheme
  p <- case rest of
    (':':digits) -> readMaybeInt digits
    _            -> Nothing
  if null h then Nothing else Just (h, p)
  where
    s = trim raw0
    readMaybeInt str = case reads str of
      [(n, "")] -> Just n
      _         -> Nothing

-- | Resolved proxy behaviour for one target host.
data ProxyChoice
  = ProxyDirect   -- ^ never use a proxy
  | ProxyFromEnv  -- ^ honour the http-client default (environment)
  | ProxyForced String Int
  deriving (Show, Eq)

-- | Pure decision core (hostAlreadyLoopback is precomputed by the caller).
resolveProxyChoice :: Bool -> Maybe String -> ProxyChoice
resolveProxyChoice loopback spec
  | loopback  = ProxyDirect
  | otherwise = case spec of
      Just "none" -> ProxyDirect
      Just u | Just (h, p) <- parseProxySpec u -> ProxyForced h p
      _           -> ProxyFromEnv

-- | Manager settings honouring the proxy policy for one target URL.
proxyAwareSettings :: String -> ManagerSettings -> IO ManagerSettings
proxyAwareSettings targetUrl base = do
  trhaProxy <- lookupEnv "TRHA_PROXY"
  let loopback = isLoopbackHost (hostOf targetUrl)
  pure $ case resolveProxyChoice loopback trhaProxy of
    ProxyDirect     -> managerSetProxy noProxy base
    ProxyFromEnv    -> base
    ProxyForced h p -> managerSetProxy (useProxy (Proxy (BS8.pack h) p)) base
  where
    hostOf u =
      let strip p s = if p `isPrefixOf` s then drop (length p) s else s
          noScheme = strip "http://" (strip "https://" u)
          noPath = takeWhile (`notElem` ("/?:@" :: String)) noScheme
      in noPath
