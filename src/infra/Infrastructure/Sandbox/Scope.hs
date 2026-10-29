{-# LANGUAGE OverloadedStrings #-}

-- | Execution scopes: one isolated domain per agent/session (ADR-001 keeps
-- @scopeId = sessionId@ at the scheduler boundary).
module Infrastructure.Sandbox.Scope
  ( ScopeId(..)
  , Isolation(..)
  , Scope(..)
  , scopeRoot
  , scopeChild
  , inherit
  ) where

import Data.Text (Text)
import Infrastructure.Sandbox.Error (SandboxError(..))
import Infrastructure.Sandbox.Policy

newtype ScopeId = ScopeId { unScopeId :: Text }
  deriving (Eq, Ord, Show)

-- | Isolation strength. 'Remote' is part of the frozen interface but every
-- backend rejects it in this version (ADR-006).
data Isolation = Shared | Process | Strong | Remote
  deriving (Eq, Ord, Show)

data Scope = Scope
  { scId        :: ScopeId
  , scParent    :: Maybe ScopeId
  , scPolicy    :: Policy
  , scScratch   :: ExclusivePath
  , scIsolation :: Isolation
  } deriving (Eq, Show)

scopeRoot :: ScopeId -> Policy -> ExclusivePath -> Scope
scopeRoot sid policy scratch = Scope
  { scId = sid
  , scParent = Nothing
  , scPolicy = policy
  , scScratch = scratch
  , scIsolation = Process
  }

-- | Build a child scope. The policy must narrow the parent's; widening is
-- rejected with 'PolicyRejected' instead of being silently clamped.
scopeChild :: Scope -> ScopeId -> Policy -> ExclusivePath -> Either SandboxError Scope
scopeChild parent sid policy scratch = case narrow (scPolicy parent) policy of
  Nothing -> Left (PolicyRejected "child policy is not a subset of its parent")
  Just narrowed -> Right Scope
    { scId = sid
    , scParent = Just (scId parent)
    , scPolicy = narrowed
    , scScratch = scratch
    , scIsolation = scIsolation parent
    }

-- | Replace a scope's policy with a narrower one.
inherit :: Scope -> Policy -> Either SandboxError Scope
inherit scope policy = case narrow (scPolicy scope) policy of
  Nothing -> Left (PolicyRejected "inherited policy is not a subset of the current one")
  Just narrowed -> Right scope { scPolicy = narrowed }
