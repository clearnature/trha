{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Endpoint probing (P2 of the provider port): ask an endpoint what it is.
--
-- The judgement is a pure function (@classifyListing@) so the decisions —
-- refused key vs missing path vs no models vs unreachable — are unit-tested
-- without a network.  The IO layer only fetches @GET {baseUrl}/models@, and
-- retries bypassing the proxy when the first attempt cannot connect
-- (matching the reference's @noProxy@ behaviour).
module API.ProviderProbe
  ( probeHandler
  , probeEndpoint
  , classifyListing
  , parseModelIds
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value(..), decode, encode, object, toJSON, (.=), (.!=), withObject, (.:), (.:?))
import Data.Aeson.Key (fromText)
import Data.Aeson.KeyMap (KeyMap)
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (catMaybes, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Servant (Handler, ServerError(..), throwError)

import Core.Provider.Types

--------------------------------------------------------------------------------
-- Pure judgement
--------------------------------------------------------------------------------

-- | Pull model ids out of whatever listing shape the endpoint answered with:
-- @{"data":[{"id":..}]}@ (OpenAI), @{"models":[..]}@, a bare array of objects
-- (@id@ / @name@) or a bare array of strings.
parseModelIds :: Value -> [Text]
parseModelIds (Object o) = maybe [] idsOf (firstOf ["data", "models"] o)
parseModelIds v@(Array _) = idsOf v
parseModelIds _ = []

firstOf :: [Text] -> KeyMap Value -> Maybe Value
firstOf keys o = listToMaybe (catMaybes [ KM.lookup (fromText k) o | k <- keys ])

idsOf :: Value -> [Text]
idsOf (Array a) = catMaybes (map elemId (V.toList a))
idsOf _ = []

elemId :: Value -> Maybe Text
elemId (String s) = Just s
elemId (Object o) = case KM.lookup "id" o of
  Just (String s) -> Just s
  _ -> case KM.lookup "name" o of
         Just (String s) -> Just s
         _               -> Nothing
elemId _ = Nothing

-- | Turn an HTTP answer into a probe result or a coded failure.
classifyListing :: Bool -> Int -> Maybe BL.ByteString -> Either ProbeError ProviderProbe
classifyListing noProxy status body
  | status == 200 =
      case body >>= (decode :: BL.ByteString -> Maybe Value) of
        Nothing -> Left (ProbeUnreachable "the endpoint's model listing was not valid JSON")
        Just v  ->
          let ms = parseModelIds v
          in if null ms
               then Left ProbeNoModels
               else Right ProviderProbe
                      { pbKind = "openai", pbKinds = ["openai", "responses"]
                      , pbAuthHeader = True, pbModels = ms, pbDefault = head ms
                      , pbEfforts = [], pbEffort = "", pbVision = []
                      , pbAmbiguous = False, pbNoProxy = noProxy }
  | status == 401 || status == 403 = Left ProbeKeyRejected
  | status == 404                  = Left ProbePathMissing
  | otherwise                      = Left (ProbeUnreachable ("HTTP " <> T.pack (show status)))

--------------------------------------------------------------------------------
-- IO: fetch the listing
--------------------------------------------------------------------------------

-- | Probe an endpoint.  Never throws on network errors: they come back as
-- @ProbeUnreachable@.  A proxy-only failure retries without the proxy.
probeEndpoint :: Text -> Text -> IO (Either ProbeError ProviderProbe)
probeEndpoint baseUrl apiKey = do
  mkReq <- parseRequest (T.unpack (T.dropWhileEnd (== '/') (T.strip baseUrl)) ++ "/models")
  let req = mkReq
        { requestHeaders = bearer apiKey
        , responseTimeout = responseTimeoutMicro 8000000
        }
  manager <- newManager tlsManagerSettings
  first <- try (httpLbs req manager) :: IO (Either SomeException (Response BL.ByteString))
  case first of
    Right resp ->
      pure (classifyListing False (statusCode (responseStatus resp)) (Just (responseBody resp)))
    Left _ -> do
      -- Retry bypassing any configured proxy; an endpoint behind a foreign
      -- exit resets the handshake, which is not a "wrong key".
      direct <- newManager (managerSetProxy noProxy tlsManagerSettings)
      second <- try (httpLbs req direct) :: IO (Either SomeException (Response BL.ByteString))
      pure $ case second of
        Right resp ->
          classifyListing True (statusCode (responseStatus resp)) (Just (responseBody resp))
        Left e -> Left (ProbeUnreachable (T.pack (show e)))
  where
    bearer k
      | T.null (T.strip k) = [("Accept", "application/json")]
      | otherwise          = [ ("Accept", "application/json")
                             , ("Authorization", "Bearer " <> TE.encodeUtf8 k) ]

--------------------------------------------------------------------------------
-- Handler
--------------------------------------------------------------------------------

probeHandler :: Value -> Handler Value
probeHandler v = case parsed of
  Left _ -> throwError (coded 400 "provider.bad_request" "expected {baseUrl, apiKey}")
  Right (baseUrl, apiKey)
    | T.null (T.strip baseUrl) ->
        throwError (coded 400 "provider.bad_request" "baseUrl is required")
    | otherwise -> do
        result <- liftIO (probeEndpoint baseUrl apiKey)
        case result of
          Left e  -> throwError (coded (probeErrorStatus e) (probeErrorCode e) (probeErrorMessage e))
          Right p -> pure (toJSON p)
  where
    parsed :: Either String (Text, Text)
    parsed = parseEither bodyParser v
    bodyParser :: Value -> Parser (Text, Text)
    bodyParser = withObject "ProbeRequest" $ \o ->
      (,) <$> o .: "baseUrl" <*> (o .:? "apiKey" .!= "")

-- | A refusal the UI can act on: HTTP status plus a machine-readable code.
coded :: Int -> Text -> Text -> ServerError
coded status code msg = ServerError
  { errHTTPCode = status
  , errReasonPhrase = T.unpack (T.replace "_" " " code)
  , errBody = encode (object [ "code" .= code, "error" .= msg ])
  , errHeaders = [("Content-Type", "application/json")]
  }
