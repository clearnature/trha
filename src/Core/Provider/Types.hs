{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Provider configuration types and pure logic (P1 of the provider port).
-- No IO here: storage lives in API.Providers, so this module stays testable.
--
-- Semantics mirror the reference implementation
-- (DeepSeek-Reasonix-studio-v2.13.0: port/provider.ts, ui/vendors.ts):
-- a provider entry is one endpoint (a "door"), `kind` is the wire format it
-- speaks, and `preset` marks a curated entry the kernel ships itself.
module Core.Provider.Types
  ( ProviderEntry(..)
  , Protocol(..)
  , ProviderStore(..)
  , emptyStore
  , normalizeStore
  , upsertProvider
  , removeProvider
  , findProvider
  , protocolCatalog
  , providerKeyEnv
  , validKinds
  , validProviderName
  , ProviderProbe(..)
  , ProbeError(..)
  , probeErrorCode
  , probeErrorStatus
  , probeErrorMessage
  , ProviderDraft(..)
  , draftToEntry
  , ProviderEdit(..)
  , applyEdit
  , editKey
  , ProviderKeys(..)
  , emptyKeys
  , lookupKey
  , insertKey
  ) where

import Data.Aeson
import Data.Char (isAlphaNum, isAscii, isUpper, toUpper)
import Data.List (find, nubBy)
import qualified Data.Map as Map
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- | One endpoint as the connection panel edits it.
data ProviderEntry = ProviderEntry
  { peName          :: Text
  , peKind          :: Text      -- ^ openai | anthropic | responses | extension
  , peBaseUrl       :: Text
  , peModels        :: [Text]
  , peDefault       :: Text
  , peHasKey        :: Bool
  , peKeyEnv        :: Maybe Text
  , peVisionModels  :: [Text]
  , pePreset        :: Bool      -- ^ shipped by the kernel, not typed by the user
  , peInUse         :: Bool
  , peContextWindow :: Maybe Int
  , peWebSearch     :: Maybe Bool   -- ^ endpoint-executed search, when set
  , peSendsThinking :: Maybe Bool   -- ^ thinking on the wire, when set
  } deriving (Show, Eq, Generic)

instance ToJSON ProviderEntry where
  toJSON p = object
    [ "name"          .= peName p
    , "kind"          .= peKind p
    , "baseUrl"       .= peBaseUrl p
    , "models"        .= peModels p
    , "default"       .= peDefault p
    , "hasKey"        .= peHasKey p
    , "keyEnv"        .= peKeyEnv p
    , "visionModels"  .= peVisionModels p
    , "preset"        .= pePreset p
    , "inUse"         .= peInUse p
    , "contextWindow" .= peContextWindow p
    , "webSearch"     .= peWebSearch p
    , "sendsThinking" .= peSendsThinking p
    ]

instance FromJSON ProviderEntry where
  parseJSON = withObject "ProviderEntry" $ \o -> ProviderEntry
    <$> o .:  "name"
    <*> (o .:? "kind"          .!= "openai")
    <*> (o .:? "baseUrl"       .!= "")
    <*> (o .:? "models"        .!= [])
    <*> (o .:? "default"       .!= "")
    <*> (o .:? "hasKey"        .!= False)
    <*> o .:? "keyEnv"
    <*> (o .:? "visionModels"  .!= [])
    <*> (o .:? "preset"        .!= False)
    <*> (o .:? "inUse"         .!= False)
    <*> o .:? "contextWindow"
    <*> o .:? "webSearch"
    <*> o .:? "sendsThinking"

-- | A wire format a source may be saved as, as the kernel declares it.
data Protocol = Protocol
  { prKind            :: Text
  , prDiscovery       :: Text    -- ^ which listing shape this wire is discovered under
  , prServerWebSearch :: Bool
  , prReasoningParams :: Bool
  } deriving (Show, Eq, Generic)

instance ToJSON Protocol where
  toJSON p = object
    [ "kind"            .= prKind p
    , "discovery"       .= prDiscovery p
    , "serverWebSearch" .= prServerWebSearch p
    , "reasoningParams" .= prReasoningParams p
    ]

instance FromJSON Protocol where
  parseJSON = withObject "Protocol" $ \o -> Protocol
    <$> o .:  "kind"
    <*> (o .:? "discovery"       .!= "openai")
    <*> (o .:? "serverWebSearch" .!= False)
    <*> (o .:? "reasoningParams" .!= False)

newtype ProviderStore = ProviderStore { psProviders :: [ProviderEntry] }
  deriving (Show, Eq, Generic)

instance ToJSON ProviderStore where
  toJSON (ProviderStore ps) = object [ "providers" .= ps ]

instance FromJSON ProviderStore where
  parseJSON = withObject "ProviderStore" $ \o ->
    ProviderStore <$> (o .:? "providers" .!= [])

-- | What an endpoint turned out to be, after probing it.  Every field is a
-- guess the user confirms before anything is written (same shape as the
-- reference implementation's ProviderProbe).
data ProviderProbe = ProviderProbe
  { pbKind       :: Text
  , pbKinds      :: [Text]     -- ^ every kind the listing may be driven with
  , pbAuthHeader :: Bool       -- ^ the endpoint accepted/expected the auth header
  , pbModels     :: [Text]
  , pbDefault    :: Text
  , pbEfforts    :: [Text]     -- ^ reasoning effort ladder, when the wire carries one
  , pbEffort     :: Text
  , pbVision     :: [Text]
  , pbAmbiguous  :: Bool       -- ^ more than one protocol answered the listing
  , pbNoProxy    :: Bool       -- ^ only answered with the proxy bypassed
  } deriving (Show, Eq, Generic)

instance ToJSON ProviderProbe where
  toJSON p = object
    [ "kind"       .= pbKind p
    , "kinds"      .= pbKinds p
    , "authHeader" .= pbAuthHeader p
    , "models"     .= pbModels p
    , "default"    .= pbDefault p
    , "efforts"    .= pbEfforts p
    , "effort"     .= pbEffort p
    , "vision"     .= pbVision p
    , "ambiguous"  .= pbAmbiguous p
    , "noProxy"    .= pbNoProxy p
    ]

instance FromJSON ProviderProbe where
  parseJSON = withObject "ProviderProbe" $ \o -> ProviderProbe
    <$> (o .:? "kind"       .!= "openai")
    <*> (o .:? "kinds"      .!= [])
    <*> (o .:? "authHeader" .!= True)
    <*> (o .:? "models"     .!= [])
    <*> (o .:? "default"    .!= "")
    <*> (o .:? "efforts"    .!= [])
    <*> (o .:? "effort"     .!= "")
    <*> (o .:? "vision"     .!= [])
    <*> (o .:? "ambiguous"  .!= False)
    <*> (o .:? "noProxy"    .!= False)

-- | Why a probe failed.  A refused key, a path the endpoint does not serve,
-- an unreachable host and a listing with no chat models are four different
-- fixes, so they are four different outcomes (coded, like the reference's).
data ProbeError
  = ProbeKeyRejected
  | ProbePathMissing
  | ProbeUnreachable Text
  | ProbeNoModels
  deriving (Show, Eq)

probeErrorCode :: ProbeError -> Text
probeErrorCode e = case e of
  ProbeKeyRejected       -> "provider.key_rejected"
  ProbePathMissing       -> "provider.path_missing"
  ProbeUnreachable _     -> "provider.unreachable"
  ProbeNoModels          -> "provider.no_models"

-- | HTTP status a failed probe maps to.
probeErrorStatus :: ProbeError -> Int
probeErrorStatus e = case e of
  ProbeKeyRejected   -> 401
  ProbePathMissing   -> 404
  ProbeUnreachable _ -> 502
  ProbeNoModels      -> 422

probeErrorMessage :: ProbeError -> Text
probeErrorMessage e = case e of
  ProbeKeyRejected    -> "the endpoint refused this API key"
  ProbePathMissing    -> "the endpoint does not serve a model listing at this path"
  ProbeUnreachable m  -> "could not reach the endpoint: " <> m
  ProbeNoModels       -> "the endpoint answered but listed no models"

--------------------------------------------------------------------------------
-- Saving a provider (P3)
--------------------------------------------------------------------------------

-- | What the panel sends after the user has looked at the probe.
data ProviderDraft = ProviderDraft
  { pdName       :: Text
  , pdKind       :: Text
  , pdBaseUrl    :: Text
  , pdApiKey     :: Text      -- ^ never persisted into the store; kept separately
  , pdModels     :: [Text]
  , pdDefault    :: Text
  , pdAuthHeader :: Bool
  , pdNoProxy    :: Bool
  , pdEffort     :: Text
  , pdVision     :: [Text]
  } deriving (Show, Eq, Generic)

instance ToJSON ProviderDraft where
  toJSON d = object
    [ "name"       .= pdName d
    , "kind"       .= pdKind d
    , "baseUrl"    .= pdBaseUrl d
    , "apiKey"     .= pdApiKey d
    , "models"     .= pdModels d
    , "default"    .= pdDefault d
    , "authHeader" .= pdAuthHeader d
    , "noProxy"    .= pdNoProxy d
    , "effort"     .= pdEffort d
    , "vision"     .= pdVision d
    ]

instance FromJSON ProviderDraft where
  parseJSON = withObject "ProviderDraft" $ \o -> ProviderDraft
    <$> (o .:? "name"       .!= "")
    <*> (o .:? "kind"       .!= "openai")
    <*> (o .:? "baseUrl"    .!= "")
    <*> (o .:? "apiKey"     .!= "")
    <*> (o .:? "models"     .!= [])
    <*> (o .:? "default"    .!= "")
    <*> (o .:? "authHeader" .!= True)
    <*> (o .:? "noProxy"    .!= False)
    <*> (o .:? "effort"     .!= "")
    <*> (o .:? "vision"     .!= [])

-- | A draft becomes the config entry we persist: the key is never written
-- here, only where it comes from (@keyEnv@) and whether we have one (@hasKey@).
draftToEntry :: ProviderDraft -> ProviderEntry
draftToEntry d = ProviderEntry
  { peName          = T.strip (pdName d)
  , peKind          = if pdKind d `elem` validKinds then pdKind d else "openai"
  , peBaseUrl       = T.strip (pdBaseUrl d)
  , peModels        = pdModels d
  , peDefault       = if T.null (pdDefault d) then pickDefault (pdModels d) else pdDefault d
  , peHasKey        = not (T.null (T.strip (pdApiKey d)))
  , peKeyEnv        = Just (providerKeyEnv (T.strip (pdName d)))
  , peVisionModels  = pdVision d
  , pePreset        = False
  , peInUse         = False
  , peContextWindow = Nothing
  , peWebSearch     = Nothing
  , peSendsThinking = Nothing
  }
  where pickDefault (m:_) = m
        pickDefault []    = ""

-- | Changing a source that already exists: everything the edit omits stays.
-- A blank key means "keep the stored one" (sending empty would clear it).
data ProviderEdit = ProviderEdit
  { eiName    :: Text
  , eiBaseUrl :: Maybe Text
  , eiApiKey  :: Maybe Text
  , eiModels  :: Maybe [Text]
  , eiDefault :: Maybe Text
  , eiVision  :: Maybe [Text]
  } deriving (Show, Eq, Generic)

instance FromJSON ProviderEdit where
  parseJSON = withObject "ProviderEdit" $ \o -> ProviderEdit
    <$> (o .:? "name" .!= "")
    <*> o .:? "baseUrl"
    <*> o .:? "apiKey"
    <*> o .:? "models"
    <*> o .:? "default"
    <*> o .:? "vision"

-- | Apply an edit, keeping every field the edit did not mention.
applyEdit :: ProviderEdit -> ProviderEntry -> ProviderEntry
applyEdit e p = p
  { peBaseUrl      = maybe (peBaseUrl p) T.strip (eiBaseUrl e)
  , peModels       = maybe (peModels p) id (eiModels e)
  , peDefault      = maybe (peDefault p) id (eiDefault e)
  , peVisionModels = maybe (peVisionModels p) id (eiVision e)
  , peHasKey       = case eiApiKey e of
                       Just k | not (T.null (T.strip k)) -> True
                       _                                 -> peHasKey p
  }

-- | The new key an edit wants stored, if it typed one.
editKey :: ProviderEdit -> Maybe Text
editKey e = case eiApiKey e of
  Just k | not (T.null (T.strip k)) -> Just k
  _                                 -> Nothing

-- | Keys live beside the config, never inside it (a config is something a
-- user pastes into an issue).
newtype ProviderKeys = ProviderKeys { pkKeys :: Map.Map Text Text }
  deriving (Show, Eq, Generic)

instance ToJSON ProviderKeys where
  toJSON (ProviderKeys m) = object [ "keys" .= m ]

instance FromJSON ProviderKeys where
  parseJSON = withObject "ProviderKeys" $ \o ->
    ProviderKeys <$> (o .:? "keys" .!= Map.empty)

emptyKeys :: ProviderKeys
emptyKeys = ProviderKeys Map.empty

lookupKey :: Text -> ProviderKeys -> Maybe Text
lookupKey n (ProviderKeys m) = Map.lookup n m

insertKey :: Text -> Text -> ProviderKeys -> ProviderKeys
insertKey n k (ProviderKeys m) = ProviderKeys (Map.insert n k m)


emptyStore :: ProviderStore
emptyStore = ProviderStore []

-- | Kinds the kernel understands (same four words as the reference's KIND_LABEL).
validKinds :: [Text]
validKinds = ["openai", "anthropic", "responses", "extension"]

-- | Never throws: coerces arbitrary persisted data into a usable store.
-- Drops entries without a name, de-duplicates by name (last one wins),
-- and coerces unknown kinds to "openai".
normalizeStore :: ProviderStore -> ProviderStore
normalizeStore (ProviderStore ps) =
  let cleaned = [ normalizeEntry p | p <- ps, not (T.null (T.strip (peName p))) ]
  in ProviderStore (dedupeByName cleaned)
  where
    normalizeEntry p = p
      { peName  = T.strip (peName p)
      , peKind  = if peKind p `elem` validKinds then peKind p else "openai"
      , peBaseUrl = T.strip (peBaseUrl p)
      }
    -- keep the last occurrence of a name (a later save wins)
    dedupeByName = reverse . nubBy (\a b -> peName a == peName b) . reverse

-- | Insert or replace by name.
upsertProvider :: ProviderEntry -> ProviderStore -> ProviderStore
upsertProvider e (ProviderStore ps) =
  ProviderStore (filter ((/= peName e) . peName) ps ++ [e])

removeProvider :: Text -> ProviderStore -> ProviderStore
removeProvider n (ProviderStore ps) = ProviderStore (filter ((/= n) . peName) ps)

findProvider :: Text -> ProviderStore -> Maybe ProviderEntry
findProvider n (ProviderStore ps) = find ((== n) . peName) ps

-- | The kernel's protocol catalog (order matters: first is the pre-selection).
protocolCatalog :: [Protocol]
protocolCatalog =
  [ Protocol "openai"    "openai"    True  True
  , Protocol "anthropic" "anthropic" False True
  , Protocol "responses" "openai"    True  True
  , Protocol "extension" "openai"    False False
  ]

-- | A name may become a config table name and part of a model reference
-- ("<provider>/<model>"), so a slash or whitespace cannot be allowed in.
-- Same rule as the reference implementation's providerNameRE:
-- @^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$@.
validProviderName :: Text -> Bool
validProviderName n =
  let t   = T.strip n
      ok c = isAlphaNum c || c `elem` ("._-" :: String)
  in case T.uncons t of
       Just (c, rest) -> isAscii c && isAlphaNum c && T.length t <= 64 && T.all ok rest
       Nothing        -> False

-- | The env var a provider's key is read from: deepseek -> DEEPSEEK_API_KEY.
-- A digit-leading name gets a CUSTOM_ prefix so the name is a valid shell var.
providerKeyEnv :: Text -> Text
providerKeyEnv name =
  let cleaned = T.map (\c -> if isAlphaNum c && isAscii c then toUpper c else '_') (T.strip name)
      body    = T.dropWhile (== '_') cleaned
      prefix  = case T.uncons body of
                  Just (c, _) | isUpper c || c == '_' -> ""
                  _                                   -> "CUSTOM_"
  in prefix <> body <> "_API_KEY"
