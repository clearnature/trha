{-# LANGUAGE OverloadedStrings #-}

-- | Windows backend (restricted token + ACL + Job Object). P0 registration
-- stub; P4 replaces it with the Rust helper protocol.
module Infrastructure.Sandbox.Backend.Windows
  ( backend
  , backendIdWindows
  ) where

import Infrastructure.Sandbox.Backend
import Infrastructure.Sandbox.Backend.Stub (unsupportedBackend)
import Infrastructure.Sandbox.Error (BackendId(..))

backendIdWindows :: BackendId
backendIdWindows = BackendId "windows-restricted-token"

backend :: Backend
backend = unsupportedBackend Windows backendIdWindows
  "Windows backend not implemented yet (P4)"
