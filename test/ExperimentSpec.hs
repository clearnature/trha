{-# LANGUAGE OverloadedStrings #-}

-- | P2 experiment-batch tests: matrix shape, narrowing, repro metadata.
module ExperimentSpec (experimentSpec) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as BLC
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
    let json = BLC.unpack (Aeson.encode (reproJson batch [("ghc", "9.14.1"), ("node", "26.12.1")]))
    json `shouldSatisfy` contains "\"batch\":\"b1\""
    json `shouldSatisfy` contains "\"seeds\":[1,2]"
    json `shouldSatisfy` contains "\"ghc\":\"9.14.1\""
    json `shouldSatisfy` contains "no-landlock"
  where
    contains needle haystack = needle `isInfix` haystack
    isInfix needle haystack = any (needle `prefix`) (suffixes haystack)
    prefix a b = take (length a) b == a
    suffixes xs = case xs of
      [] -> [[]]
      (_ : rest) -> xs : suffixes rest
    distinct = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

parent :: Scope
parent = scopeRoot (ScopeId "session-1") (WorkspaceWrite WritableRoot
  { wrRoot = AbsolutePath "/ws"
  , wrScratch = ExclusivePath (AbsolutePath "/ws/.work")
  , wrReadOnly = []
  , wrNetwork = NetworkOff
  , wrLimits = defaultResourceLimits
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
