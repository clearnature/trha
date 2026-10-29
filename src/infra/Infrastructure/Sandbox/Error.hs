{-# LANGUAGE OverloadedStrings #-}

-- | Error and probe vocabulary shared by the sandbox modules. Kept in its own
-- module so Policy/Scope/Plan/Backend can refer to it without cycles.
module Infrastructure.Sandbox.Error
  ( BackendId(..)
  , SandboxError(..)
  , ProbeResult(..)
  ) where

import Data.Text (Text)

newtype BackendId = BackendId { unBackendId :: Text }
  deriving (Eq, Ord, Show)

data ProbeResult = ProbeResult
  { probeName     :: Text
  , probeOk       :: Bool
  , probeExpected :: Text
  , probeActual   :: Text
  } deriving (Eq, Show)

-- | Fail-closed error type: every constructor means "do not run the command".
data SandboxError
  = SandboxUnavailable BackendId Text
  | PolicyRejected Text
  | RenderFailed Text
  | LaunchFailed Text
  | ProbeFailed [ProbeResult]
  deriving (Eq, Show)
