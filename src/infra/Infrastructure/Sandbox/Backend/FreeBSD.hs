{-# LANGUAGE OverloadedStrings #-}

-- | FreeBSD backend (Capsicum). P0 registration stub; P5 replaces it.
module Infrastructure.Sandbox.Backend.FreeBSD
  ( backend
  , backendIdFreeBSD
  ) where

import Infrastructure.Sandbox.Backend
import Infrastructure.Sandbox.Backend.Stub (unsupportedBackend)
import Infrastructure.Sandbox.Error (BackendId(..))

backendIdFreeBSD :: BackendId
backendIdFreeBSD = BackendId "freebsd-capsicum"

backend :: Backend
backend = unsupportedBackend FreeBSD backendIdFreeBSD
  "FreeBSD backend not implemented yet (P5)"
