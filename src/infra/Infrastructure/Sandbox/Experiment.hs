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
  ) where

import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson.Key as Key
import Data.Text (Text)
import qualified Data.Text as T
import Infrastructure.Sandbox.Error (SandboxError(..))
import Infrastructure.Sandbox.Policy
import Infrastructure.Sandbox.Scope
import System.FilePath ((</>))

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
