{-# LANGUAGE OverloadedStrings #-}

-- | Shared stub used by every platform backend until its P-stage lands.
-- Probes fail with 'SandboxUnavailable', so 'planWith' never renders a plan
-- for a backend that cannot enforce it.
module Infrastructure.Sandbox.Backend.Stub
  ( unsupportedBackend
  ) where

import Data.Text (Text)
import Infrastructure.Sandbox.Backend
import Infrastructure.Sandbox.Error
import Infrastructure.Sandbox.Plan
import Infrastructure.Sandbox.Scope

unsupportedBackend :: Platform -> BackendId -> Text -> Backend
unsupportedBackend _platform bid note = Backend
  { backendId = bid
  , backendProbe = pure (Left (SandboxUnavailable bid note))
  , backendRender = \_ _ -> Left (SandboxUnavailable bid note)
  }
