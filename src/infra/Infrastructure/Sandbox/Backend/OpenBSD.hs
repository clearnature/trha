{-# LANGUAGE OverloadedStrings #-}

-- | OpenBSD backend (pledge + unveil). P0 registration stub; P5 replaces it.
module Infrastructure.Sandbox.Backend.OpenBSD
  ( backend
  , backendIdOpenBSD
  ) where

import Infrastructure.Sandbox.Backend
import Infrastructure.Sandbox.Backend.Stub (unsupportedBackend)
import Infrastructure.Sandbox.Error (BackendId(..))

backendIdOpenBSD :: BackendId
backendIdOpenBSD = BackendId "openbsd-pledge"

backend :: Backend
backend = unsupportedBackend OpenBSD backendIdOpenBSD
  "OpenBSD backend not implemented yet (P5)"
