{-# LANGUAGE OverloadedStrings #-}

-- | P2 experiment-batch tests: matrix shape, narrowing, repro metadata.
module ExperimentSpec (experimentSpec) where

import Data.Aeson (Value, toJSON)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Text (Text)
import qualified Data.Text as T
import Data.Either (isLeft)
import Infrastructure.Sandbox.Experiment
import Infrastructure.Sandbox.Policy
import Infrastructure.Sandbox.Scope
import Test.Hspec

experimentSpec :: Spec
experimentSpec = describe "experiment batch (T2.7/T2.8)" $ do
  it "builds one scope per (variant, seed)" $ do
    case batchScopes parent batch of
      Left e -> expectationFailure (show e)
      Right scopes -> do
        length scopes `shouldBe` 4
        let ids = [ unScopeId (scId s) | (_, _, s) <- scopes ]
        length (distinct ids) `shouldBe` 4

  it "gives each variant its own writable root with work/ inside it" $ do
    case variantScope parent batch (headVariant batch) (Seed 1) of
      Left e -> expectationFailure (show e)
      Right scope -> do
        scParent scope `shouldBe` Just (ScopeId "b1")
        case scPolicy scope of
          WorkspaceWrite wr -> do
            unAbsolutePath (wrRoot wr) `shouldBe` "/ws/experiments/b1/no-landlock/1"
            unAbsolutePath (unExclusivePath (wrScratch wr))
              `shouldBe` "/ws/experiments/b1/no-landlock/1/work"
            unAbsolutePath (ebBaseline batch) `elem`
              map unAbsolutePath (wrReadOnly wr) `shouldBe` True
          other -> expectationFailure ("expected workspace-write, got " ++ show other)

  it "rejects a batch root outside the parent's writable root" $ do
    let escaped = batch { ebRoot = AbsolutePath "/elsewhere/b1"
                        , ebBaseline = AbsolutePath "/elsewhere/b1/baseline" }
    batchScopes parent escaped `shouldSatisfy` isLeft

  it "rejects a variant that widens the network policy" $ do
    let widening = Variant (VariantId "net") (NetworkAllow ["example.com"])
    variantScope parent batch widening (Seed 1) `shouldSatisfy` isLeft

  it "writes reproducibility metadata" $ do
    let json = BLC.unpack (Aeson.encode
          (reproJson (Just "cold") (Just "probe-user") batch
                     [("ghc", "9.14.1"), ("node", "26.12.1")]))
    json `shouldSatisfy` contains "\"batch\":\"b1\""
    json `shouldSatisfy` contains "\"seeds\":[1,2]"
    json `shouldSatisfy` contains "\"ghc\":\"9.14.1\""
    -- KVCache makes cost non-comparable: cold vs warm must be on the record.
    json `shouldSatisfy` contains "\"cacheState\":\"cold\""
    json `shouldSatisfy` contains "\"userId\":\"probe-user\""
    json `shouldSatisfy` contains "no-landlock"

  -- T2.8 executor shape: the policy hash is stable, and a different masking
  -- set is a different experiment even when every visible field matches.
  it "hashes the effective policy stably and differentiates a masked set" $ do
    -- Pin the canonical text first — this exact string is what both sides
    -- digest. The form is an explicit key-order rendering, not aeson's
    -- Generic encoding (which sorts fields alphabetically and would make the
    -- hash depend on field names).
    T.unpack (canonicalPolicyText (WorkspaceWrite batchRootPolicy))
      `shouldBe` canonicalPolicyString
    let h = policyHashJson (WorkspaceWrite batchRootPolicy)
        widened = batchRootPolicy { wrDenyReadDirs = Just [".ssh"] }
    h `shouldSatisfy` matchesHex32
    policyHashJson (WorkspaceWrite batchRootPolicy) `shouldBe` h
    policyHashJson (WorkspaceWrite widened) `shouldNotBe` h

  -- Cross-language differential with the scheduler's writer:
  -- packages/scheduler/test/sandbox.test.ts asserts the same literal, built
  -- from the same canonical string. Either side drifting turns one of the
  -- two suites red.
  it "matches the scheduler's canonical policy encoding" $
    policyHashJson (WorkspaceWrite batchRootPolicy)
      `shouldBe` T.pack expectedSchedulerHash
  where
    contains needle haystack = needle `isInfix` haystack
    isInfix needle haystack = any (needle `prefix`) (suffixes haystack)
    prefix a b = take (length a) b == a
    suffixes xs = case xs of
      [] -> [[]]
      (_ : rest) -> xs : suffixes rest
    distinct = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- | The byte-exact canonical text both languages hash. Explicit key order:
-- tag | root | scratch | ro-read-only | network | pids,mem,wall | denyDirs | denyFiles.
canonicalPolicyString :: String
canonicalPolicyString =
  "workspace-write|\"/ws/experiments/b1\""
    <> "|\"/ws/experiments/b1/.batch-work\""
    <> "|[\"/ws/experiments/b1/baseline\"]"
    <> "|off|0,0,600000|-|-"

-- | The batch-root policy the scheduler's runExperiment canonicalises for
-- its fixture (id b1, root /ws/experiments/b1, baseline …/baseline).
batchRootPolicy :: WritableRoot
batchRootPolicy = WritableRoot
  { wrRoot = AbsolutePath "/ws/experiments/b1"
  , wrScratch = ExclusivePath (AbsolutePath "/ws/experiments/b1/.batch-work")
  , wrReadOnly = [AbsolutePath "/ws/experiments/b1/baseline"]
  , wrNetwork = NetworkOff
  , wrLimits = defaultResourceLimits
  , wrDenyReadDirs = Nothing
  , wrDenyReadFiles = Nothing
  }

-- | sha512(canonicalPolicyString) truncated to 32 hex chars; equals what
-- the scheduler's computePolicyHash produces for the same fixture
-- (cross-language pin — its test asserts the same literal).
expectedSchedulerHash :: String
expectedSchedulerHash = "e8b065d988e2ae560939865205581095"

matchesHex32 :: Text -> Bool
matchesHex32 t = T.length t == 32 && all (`elem` (T.unpack "0123456789abcdef")) (T.unpack t)

parent :: Scope
parent = scopeRoot (ScopeId "session-1") (WorkspaceWrite WritableRoot
  { wrRoot = AbsolutePath "/ws"
  , wrScratch = ExclusivePath (AbsolutePath "/ws/.work")
  , wrReadOnly = []
  , wrNetwork = NetworkOff
  , wrLimits = defaultResourceLimits
  , wrDenyReadDirs = Nothing
  , wrDenyReadFiles = Nothing
  }) (ExclusivePath (AbsolutePath "/ws/.work"))

batch :: ExperimentBatch
batch = ExperimentBatch
  { ebId = BatchId "b1"
  , ebRoot = AbsolutePath "/ws/experiments/b1"
  , ebBaseline = AbsolutePath "/ws/experiments/b1/baseline"
  , ebVariants =
      [ Variant (VariantId "no-landlock") NetworkOff
      , Variant (VariantId "no-seccomp") NetworkOff
      ]
  , ebSeeds = [Seed 1, Seed 2]
  , ebLimits = defaultResourceLimits
  , ebConcurrency = 2
  }

headVariant :: ExperimentBatch -> Variant
headVariant b = case ebVariants b of
  (v : _) -> v
  [] -> Variant (VariantId "none") NetworkOff
