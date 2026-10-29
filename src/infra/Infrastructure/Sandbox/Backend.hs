{-# LANGUAGE OverloadedStrings #-}

-- | Backend interface and the pure capability check.
--
-- A backend is a record of pure renderers plus one IO probe. 'planWith' is
-- the only entry point: it refuses to render when the backend cannot
-- guarantee every capability the policy asks for (fail-closed).
module Infrastructure.Sandbox.Backend
  ( Platform(..)
  , BackendId(..)
  , BackendCapabilities(..)
  , Backend(..)
  , planWith
  , capSupported
  ) where

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Infrastructure.Sandbox.Error
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Policy
import Infrastructure.Sandbox.Scope

data Platform
  = Linux
  | FreeBSD
  | OpenBSD
  | Darwin
  | Windows
  | Android
  | Other Text
  deriving (Eq, Ord, Show)

data BackendCapabilities = BackendCapabilities
  { bcBackend      :: BackendId
  , bcPlatform     :: Platform
  , bcCapabilities :: Set Capability
  , bcEnforcement  :: Enforcement
  , bcNotes        :: [Text]
  } deriving (Eq, Show)

data Backend = Backend
  { backendId     :: BackendId
  , backendProbe  :: IO (Either SandboxError BackendCapabilities)
  , backendRender :: Scope -> LaunchRequest -> Either SandboxError LaunchPlan
  }

-- | @capSupported caps required@: every required capability is declared.
capSupported :: BackendCapabilities -> Set Capability -> Bool
capSupported caps required = required `Set.isSubsetOf` bcCapabilities caps

-- | Check capabilities/enforcement, then render. 'None' enforcement always
-- fails: a platform without an OS sandbox must not run commands.
planWith :: Backend -> BackendCapabilities -> Scope -> LaunchRequest
         -> Either SandboxError LaunchPlan
planWith backend caps scope req = case bcEnforcement caps of
  None reason -> Left (SandboxUnavailable (bcBackend caps) reason)
  _ -> do
    let required = policyCapabilities (scPolicy scope)
    if capSupported caps required
      then backendRender backend scope req
      else Left (SandboxUnavailable (bcBackend caps)
        ("missing capabilities: " <> renderMissing caps required))
  where
    renderMissing c r = Text.intercalate ", "
      (map (Text.pack . show) (Set.toList (r `Set.difference` bcCapabilities c)))
