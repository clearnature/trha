{-# LANGUAGE OverloadedStrings #-}

-- | Experiment batches (P2, docs/plans/sandbox-architecture.md §5.3.1).
--
-- A batch is an orchestration view over a matrix of scopes:
--
-- > <state>/experiments/<batch>/baseline/          read-only in every variant
-- > <state>/experiments/<batch>/<variant>/<seed>/  writable root per scope
-- >                                          work/  exclusive scratch
-- >                                          out/   results (host reads only)
--
-- The batch root and every variant are built through 'scopeChild', so a
-- variant can only narrow the parent's policy. Directory layout is fixed by
-- 'narrow's rule that a scratch directory must sit under its writable root.
module Infrastructure.Sandbox.Experiment
  ( BatchId(..)
  , VariantId(..)
  , Seed(..)
  , Variant(..)
  , ExperimentBatch(..)
  , batchRootScope
  , variantScope
  , batchScopes
  , variantDir
  , workDir
  , outDir
  , reproJson
  , policyHashJson
  , canonicalPolicyText
  , writeReproJson
  , reproFileJson
  ) where

import Crypto.Hash (Digest, hashlazy, SHA512(SHA512))
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString.Lazy as BL
import Data.Bits ((.&.), shiftR)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Infrastructure.Sandbox.Error (SandboxError(..))
import Infrastructure.Sandbox.Policy
import Infrastructure.Sandbox.Scope
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)

-- | Canonical hash of a policy (§5.7.5 `reproduce`): SHA-512 over the
-- canonical text below, truncated to 32 hex chars. A rerun whose
-- @policyHash@ differs is not the same experiment — since read.deny became
-- part of the policy, the masking set changes the hash too.
--
-- The canonical form is deliberately NOT aeson's Generic encoding (which
-- sorts record fields alphabetically and tags constructors with
-- @{tag, contents}@): that shape silently depends on field *names* and the
-- aeson version. Instead it is an explicit key-order-preserving rendering —
-- constructor tag first, then WritableRoot fields in declaration order —
-- which the scheduler's TypeScript writer reproduces byte for byte. Both
-- sides pin the exact string in their tests; drift turns one red.
policyHashJson :: Policy -> Text
policyHashJson policy = T.take 32 (hexOf digest)
  where
    digest = hashlazy (BL.fromStrict (TE.encodeUtf8 (canonicalPolicyText policy))) :: Digest SHA512
    hexOf d = T.pack (concatMap word (BS.unpack (BA.convert d :: BS.ByteString)))
    word b = [nibble (fromIntegral b `shiftR` 4), nibble (fromIntegral b .&. 0xf)]
    nibble n
      | n < 10 = toEnum (n + fromEnum '0')
      | otherwise = toEnum (n - 10 + fromEnum 'a')

-- | The canonical text both languages agree on. Quoting follows JSON: a
-- plain double-quote wrapper suffices because these paths and tags contain
-- no escapes (a quote inside a root would be rejected long before hashing).
canonicalPolicyText :: Policy -> Text
canonicalPolicyText policy = case policy of
  DangerFullAccess -> "danger-full-access"
  ReadOnly ro -> T.intercalate "|"
    [ "read-only"
    , cpList (map cpQuoteAbs (roReadableRoots ro))
    , cpNetwork (roNetwork ro)
    , cpList (map cpQuote (roEnvAllow ro))
    ]
  WorkspaceWrite wr -> T.intercalate "|"
    [ "workspace-write"
    , cpQuoteAbs (wrRoot wr)
    , cpQuoteAbs (unExclusivePath (wrScratch wr))
    , cpList (map cpQuoteAbs (wrReadOnly wr))
    , cpNetwork (wrNetwork wr)
    , T.intercalate ","
        [ T.pack (show (rlPids (wrLimits wr)))
        , T.pack (show (rlMemoryMiB (wrLimits wr)))
        , T.pack (show (rlWallMs (wrLimits wr)))
        ]
    , cpDeny (wrDenyReadDirs wr)
    , cpDeny (wrDenyReadFiles wr)
    ]

-- Canonical-text helpers (top level: a @where@ under a @case ... of@ body
-- collides with the layout rule — measured GHC-58481).
cpQuote :: Text -> Text
cpQuote t = "\"" <> t <> "\""

cpQuoteAbs :: AbsolutePath -> Text
cpQuoteAbs (AbsolutePath p) = cpQuote (T.pack p)

cpList :: [Text] -> Text
cpList xs = "[" <> T.intercalate "," xs <> "]"

cpNetwork :: NetworkPolicy -> Text
cpNetwork NetworkOff = "off"
cpNetwork (NetworkAllow ds) = "allow:" <> T.intercalate "," ds
cpNetwork (NetworkProxy url) = "proxy:" <> url

cpDeny :: Maybe [Text] -> Text
cpDeny Nothing = "-"
cpDeny (Just xs) = cpList (map cpQuote xs)

-- | Write @repro.json@ next to the batch results: the executor side of T2.8.
-- Creates the root if needed; returns the path written.
writeReproJson :: FilePath -> Value -> IO FilePath
writeReproJson root value = do
  let path = root </> "repro.json"
  createDirectoryIfMissing True (takeDirectory path)
  BL.writeFile path (encode value)
  pure path

-- | The @repro.json@ shape as the *executor* writes it (T2.8). Mirrors
-- 'reproJson' plus what only the running host knows: per-variant outcomes,
-- toolchain, and the policy hash. Kept pure so both sides — Haskell callers
-- and the scheduler's JSON writer — have one canonical field list to match.
reproFileJson ::
     Maybe Text        -- ^ cacheState (cold|warm); Nothing when unknown
  -> Maybe Text        -- ^ userId
  -> ExperimentBatch
  -> [(Text, Text)]    -- ^ toolchain entries (name, version/path)
  -> Policy            -- ^ effective batch-root policy → policyHash
  -> [(Text, Int, Bool, Int)]  -- ^ (variant, seed, ok, attempt) results
  -> Value
reproFileJson cacheState userId batch toolchain policy results = object
  [ "batch" .= unBatchId (ebId batch)
  , "cacheState" .= cacheState
  , "userId" .= userId
  , "baseline" .= unAbsolutePath (ebBaseline batch)
  , "root" .= unAbsolutePath (ebRoot batch)
  , "policyHash" .= policyHashJson policy
  , "toolchain" .= object [ Key.fromText k .= v | (k, v) <- toolchain ]
  , "variants" .= [ object
      [ "id" .= unVariantId (vId v)
      , "network" .= show (vNetwork v)
      ] | v <- ebVariants batch ]
  , "seeds" .= map unSeed (ebSeeds batch)
  , "concurrency" .= ebConcurrency batch
  , "results" .= [ object
      [ "variant" .= vid, "seed" .= seed, "ok" .= ok, "attempt" .= att ]
    | (vid, seed, ok, att) <- results ]
  ]

newtype BatchId = BatchId { unBatchId :: Text }
  deriving (Eq, Ord, Show)

newtype VariantId = VariantId { unVariantId :: Text }
  deriving (Eq, Ord, Show)

newtype Seed = Seed { unSeed :: Int }
  deriving (Eq, Ord, Show)

data Variant = Variant
  { vId      :: VariantId
  , vNetwork :: NetworkPolicy
  } deriving (Eq, Show)

data ExperimentBatch = ExperimentBatch
  { ebId          :: BatchId
  , ebRoot        :: AbsolutePath
  , ebBaseline    :: AbsolutePath
  , ebVariants    :: [Variant]
  , ebSeeds       :: [Seed]
  , ebLimits      :: ResourceLimits
  , ebConcurrency :: Int
  } deriving (Eq, Show)

-- | @<root>/<variant>/<seed>@.
variantDir :: ExperimentBatch -> Variant -> Seed -> FilePath
variantDir batch variant seed =
  unAbsolutePath (ebRoot batch)
    </> T.unpack (unVariantId (vId variant))
    </> show (unSeed seed)

workDir :: ExperimentBatch -> Variant -> Seed -> FilePath
workDir batch variant seed = variantDir batch variant seed </> "work"

outDir :: ExperimentBatch -> Variant -> Seed -> FilePath
outDir batch variant seed = variantDir batch variant seed </> "out"

-- | The batch's own scope: writable root = the batch directory, baseline
-- mounted read-only, network off for the execution phase.
batchRootScope :: Scope -> ExperimentBatch -> Either SandboxError Scope
batchRootScope parent batch =
  scopeChild parent (ScopeId (unBatchId (ebId batch))) (batchPolicy batch) (ExclusivePath (AbsolutePath batchWork))
  where
    root = unAbsolutePath (ebRoot batch)
    batchWork = root </> ".batch-work"
    batchPolicy b = WorkspaceWrite WritableRoot
      { wrRoot = ebRoot b
      , wrScratch = ExclusivePath (AbsolutePath batchWork)
      , wrReadOnly = [ebBaseline b]
      , wrNetwork = NetworkOff
      , wrLimits = ebLimits b
      , wrDenyReadDirs = Nothing
      , wrDenyReadFiles = Nothing
      }

-- | One scope per @(variant, seed)@. The writable root is the variant
-- directory, so @work/@ (scratch) and @out/@ (results) both live inside it
-- while other variants stay invisible to the writable set.
variantScope :: Scope -> ExperimentBatch -> Variant -> Seed -> Either SandboxError Scope
variantScope parent batch variant seed = do
  root <- batchRootScope parent batch
  let dir = variantDir batch variant seed
      work = workDir batch variant seed
      policy = WorkspaceWrite WritableRoot
        { wrRoot = AbsolutePath dir
        , wrScratch = ExclusivePath (AbsolutePath work)
        , wrReadOnly = [ebBaseline batch]
        , wrNetwork = vNetwork variant
        , wrLimits = ebLimits batch
        , wrDenyReadDirs = Nothing
        , wrDenyReadFiles = Nothing
        }
  scopeChild root
    (ScopeId (unBatchId (ebId batch) <> "/" <> unVariantId (vId variant) <> "/" <> T.pack (show (unSeed seed))))
    policy
    (ExclusivePath (AbsolutePath work))

-- | The full @variants × seeds@ matrix, in declaration order.
batchScopes :: Scope -> ExperimentBatch -> Either SandboxError [(Variant, Seed, Scope)]
batchScopes parent batch = traverse build pairs
  where
    pairs = [ (v, s) | v <- ebVariants batch, s <- ebSeeds batch ]
    build (v, s) = (,,) v s <$> variantScope parent batch v s

-- | Reproducibility metadata written next to the results (T2.8).
--
-- @cacheState@ / @userId@ are recorded because KVCache makes cost and latency
-- non-comparable across runs: the same (variant, seed) costs an order of
-- magnitude more on a cold cache than on a warm one, and a shared @user_id@
-- lets one variant warm the cache for another. Without these two fields a
-- rerun looks "reproducible" while its numbers are not.
reproJson :: Maybe Text -> Maybe Text -> ExperimentBatch -> [(Text, Text)] -> Value
reproJson cacheState userId batch toolchain = object
  [ "batch" .= unBatchId (ebId batch)
  , "cacheState" .= cacheState
  , "userId" .= userId
  , "baseline" .= unAbsolutePath (ebBaseline batch)
  , "root" .= unAbsolutePath (ebRoot batch)
  , "toolchain" .= object [ Key.fromText k .= v | (k, v) <- toolchain ]
  , "variants" .= [ object
      [ "id" .= unVariantId (vId v)
      , "network" .= show (vNetwork v)
      ] | v <- ebVariants batch ]
  , "seeds" .= map unSeed (ebSeeds batch)
  , "concurrency" .= ebConcurrency batch
  ]
