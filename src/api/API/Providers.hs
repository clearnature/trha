{-# LANGUAGE OverloadedStrings #-}

-- | Provider storage + HTTP handlers (P1 list/protocols, P3 save/remove/check).
--
-- Config lives at @~/.trha/providers.json@; keys live separately at
-- @~/.trha/provider-keys.json@ so a config never carries a secret (the same
-- split the reference implementation makes).  Both are written atomically
-- (temp file + rename).
module API.Providers
  ( providerFilePath
  , keysFilePath
  , loadProviderStore
  , saveProviderStore
  , loadKeys
  , saveKeys
  , resolveKey
  , providersHandler
  , protocolsHandler
  , saveProviderHandler
  , removeProviderHandler
  , checkProviderHandler
  , editProviderHandler
  , setWebSearchHandler
  , setThinkingHandler
  , setInUseHandler
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, decode, encode, object, parseJSON, toJSON, withObject, (.:), (.:?), (.=), (.!=))
import Data.Aeson.Types (parseEither)
import Data.Maybe (isNothing)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Servant (Handler, ServerError(..), throwError)
import System.Directory (createDirectoryIfMissing, doesFileExist, getHomeDirectory, renameFile)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))

import API.ProviderProbe (probeEndpoint)
import API.ProviderRuntime (invalidateProviderCaches)
import Core.Provider.Types

-- | @~/.trha/providers.json@ — the endpoints, never their keys.
-- @TRHA_PROVIDERS_FILE@ overrides the location (used by tests).
providerFilePath :: IO FilePath
providerFilePath = do
  override <- lookupEnv "TRHA_PROVIDERS_FILE"
  case override of
    Just p | not (null p) -> pure p
    _ -> do
      home <- getHomeDirectory
      pure (home </> ".trha" </> "providers.json")

-- | @~/.trha/provider-keys.json@ — the secrets, kept apart from the config.
-- @TRHA_PROVIDER_KEYS_FILE@ overrides the location (used by tests).
keysFilePath :: IO FilePath
keysFilePath = do
  override <- lookupEnv "TRHA_PROVIDER_KEYS_FILE"
  case override of
    Just p | not (null p) -> pure p
    _ -> do
      home <- getHomeDirectory
      pure (home </> ".trha" </> "provider-keys.json")

-- | Load the store; a missing or unreadable file degrades to an empty store
-- (never throws), so a corrupt file cannot take the kernel down.
loadProviderStore :: IO ProviderStore
loadProviderStore = do
  f <- providerFilePath
  exists <- doesFileExist f
  if not exists
    then pure emptyStore
    else do
      r <- try (BL.readFile f) :: IO (Either SomeException BL.ByteString)
      pure $ case r of
        Left _   -> emptyStore
        Right bs -> maybe emptyStore normalizeStore (decode bs)

-- | Persist the store atomically (temp file + rename in the same directory).
saveProviderStore :: ProviderStore -> IO ()
saveProviderStore store = do
  f <- providerFilePath
  createDirectoryIfMissing True (takeDirectory f)
  let tmp = f ++ ".tmp"
  BL.writeFile tmp (encode (normalizeStore store))
  renameFile tmp f

loadKeys :: IO ProviderKeys
loadKeys = do
  f <- keysFilePath
  exists <- doesFileExist f
  if not exists
    then pure emptyKeys
    else do
      r <- try (BL.readFile f) :: IO (Either SomeException BL.ByteString)
      pure $ case r of
        Left _   -> emptyKeys
        Right bs -> maybe emptyKeys id (decode bs)

saveKeys :: ProviderKeys -> IO ()
saveKeys keys = do
  f <- keysFilePath
  createDirectoryIfMissing True (takeDirectory f)
  let tmp = f ++ ".tmp"
  BL.writeFile tmp (encode keys)
  renameFile tmp f

-- | GET /providers
providersHandler :: Handler Value
providersHandler = liftIO (toJSON <$> loadProviderStore)

-- | GET /providers/protocols
protocolsHandler :: Handler Value
protocolsHandler = pure (toJSON protocolCatalog)

--------------------------------------------------------------------------------
-- P3: save / remove / check
--------------------------------------------------------------------------------

-- | The key for a provider: the stored one, else whatever its @keyEnv@ names.
resolveKey :: Text -> ProviderKeys -> IO (Maybe Text)
resolveKey name keys = case lookupKey name keys of
  Just k | not (T.null (T.strip k)) -> pure (Just k)
  _ -> do
    store <- loadProviderStore
    case findProvider name store >>= peKeyEnv of
      Just envVar -> fmap (fmap T.pack) (lookupEnv (T.unpack envVar))
      Nothing     -> pure Nothing

-- | POST /providers — save one provider (and its key, when one was typed).
saveProviderHandler :: Value -> Handler Value
saveProviderHandler v = case parseEither parseJSON v of
  Left e -> throwError (coded 400 "provider.bad_request" (T.pack e))
  Right d
    | T.null (T.strip (pdName d))    -> throwError (coded 400 "provider.bad_request" "name is required")
    | not (validProviderName (pdName d)) ->
        throwError (coded 400 "provider.bad_name"
          "name must start with a letter or digit and contain only letters, digits, dot, underscore and dash (max 64)")
    | T.null (T.strip (pdBaseUrl d)) -> throwError (coded 400 "provider.bad_request" "baseUrl is required")
    | otherwise -> do
        store <- liftIO loadProviderStore
        keys <- liftIO loadKeys
        let entry = draftToEntry d
            store' = upsertProvider entry store
        liftIO $ do
          saveProviderStore store'
          invalidateProviderCaches
          if T.null (T.strip (pdApiKey d))
            then pure ()
            else saveKeys (insertKey (peName entry) (pdApiKey d) keys)
        pure (toJSON store')

-- | POST /providers/remove
removeProviderHandler :: Value -> Handler Value
removeProviderHandler v = case parseEither (withObject "RemoveRequest" (\o -> o .: "name")) v of
  Left e -> throwError (coded 400 "provider.bad_request" (T.pack e))
  Right name -> do
    store <- liftIO loadProviderStore
    let store' = removeProvider name store
    liftIO (saveProviderStore store' >> invalidateProviderCaches)
    pure (toJSON store')

-- | POST /providers/check — re-probe a saved provider and report what it found.
checkProviderHandler :: Value -> Handler Value
checkProviderHandler v = case parseEither (withObject "CheckRequest" (\o -> o .: "name")) v of
  Left e -> throwError (coded 400 "provider.bad_request" (T.pack e))
  Right name -> do
    store <- liftIO loadProviderStore
    case findProvider name store of
      Nothing -> throwError (coded 404 "provider.not_found" ("no provider named " <> name))
      Just entry -> do
        mkey <- liftIO (resolveKey name =<< loadKeys)
        result <- liftIO (probeEndpoint (peBaseUrl entry) (maybe "" id mkey))
        pure $ case result of
          Right p -> object
            [ "ok"        .= True
            , "kind"      .= pbKind p
            , "models"    .= pbModels p
            , "ambiguous" .= pbAmbiguous p
            , "noProxy"   .= pbNoProxy p
            ]
          Left e -> object
            [ "ok"    .= False
            , "error" .= probeErrorMessage e
            , "code"  .= probeErrorCode e
            ]

-- | POST /providers/edit — change a source; omitted fields stay put.
editProviderHandler :: Value -> Handler Value
editProviderHandler v = case parseEither parseJSON v of
  Left e -> throwError (coded 400 "provider.bad_request" (T.pack e))
  Right e
    | not (validProviderName (eiName e)) ->
        throwError (coded 400 "provider.bad_name"
          "name must start with a letter or digit and contain only letters, digits, dot, underscore and dash (max 64)")
    | otherwise -> do
        store <- liftIO loadProviderStore
        case findProvider (eiName e) store of
          Nothing -> throwError (coded 404 "provider.not_found" ("no provider named " <> eiName e))
          Just entry -> do
            let store' = upsertProvider (applyEdit e entry) store
            liftIO $ do
              saveProviderStore store'
              invalidateProviderCaches
              case editKey e of
                Just k  -> do keys <- loadKeys; saveKeys (insertKey (eiName e) k keys)
                Nothing -> pure ()
            pure (toJSON store')

-- | POST /providers/websearch {name, on}
setWebSearchHandler :: Value -> Handler Value
setWebSearchHandler = setToggle (\p on -> p { peWebSearch = Just on })

-- | POST /providers/thinking {name, on}
setThinkingHandler :: Value -> Handler Value
setThinkingHandler = setToggle (\p on -> p { peSendsThinking = Just on })

-- | POST /providers/in-use — make one saved provider the active one.
setInUseHandler :: Value -> Handler Value
setInUseHandler v = case parseEither (withObject "InUseRequest" (\o -> o .: "name")) v of
  Left e -> throwError (coded 400 "provider.bad_request" (T.pack e))
  Right name -> do
    store <- liftIO loadProviderStore
    if isNothing (findProvider name store)
      then throwError (coded 404 "provider.not_found" ("no provider named " <> name))
      else do
        let store' = ProviderStore
              [ if peName p == name then p { peInUse = True } else p { peInUse = False }
              | p <- psProviders store ]
        liftIO (saveProviderStore store' >> invalidateProviderCaches)
        pure (toJSON store')

-- | Flip one on/off field of a saved provider.
setToggle :: (ProviderEntry -> Bool -> ProviderEntry) -> Value -> Handler Value
setToggle update v = case parseEither (withObject "Toggle" (\o -> (,) <$> o .: "name" <*> (o .:? "on" .!= False))) v of
  Left e -> throwError (coded 400 "provider.bad_request" (T.pack e))
  Right (name, on) -> do
    store <- liftIO loadProviderStore
    case findProvider name store of
      Nothing    -> throwError (coded 404 "provider.not_found" ("no provider named " <> name))
      Just entry -> do
        let store' = upsertProvider (update entry on) store
        liftIO (saveProviderStore store')
        pure (toJSON store')

-- | A refusal the UI can act on: HTTP status plus a machine-readable code.
coded :: Int -> Text -> Text -> ServerError
coded status code msg = ServerError
  { errHTTPCode = status
  , errReasonPhrase = T.unpack (T.replace "_" " " code)
  , errBody = encode (object [ "code" .= code, "error" .= msg ])
  , errHeaders = [("Content-Type", "application/json")]
  }
