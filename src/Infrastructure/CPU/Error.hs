{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.CPU.Error
  ( -- * Error Handling
    CPUError(..)
  , errorToText
  , isRecoverableError
  , errorSeverity
  , ErrorSeverity(..)
  ) where

import Infrastructure.CPU.Types
import Data.Text (Text)

-- | Error severity
data ErrorSeverity
  = SeverityInfo
  | SeverityWarning
  | SeverityError
  | SeverityCritical
  deriving (Show, Eq, Ord)

-- | Convert error to text
errorToText :: CPUError -> Text
errorToText (ThreadError msg) = "Thread error: " <> msg
errorToText SIMDNotSupported = "SIMD not supported"
errorToText BLASNotAvailable = "BLAS not available"
errorToText (ArchitectureNotSupported arch) = "Architecture not supported: " <> Data.Text.pack (show arch)
errorToText (UnknownCPUError msg) = "Unknown CPU error: " <> msg

-- | Check if error is recoverable
isRecoverableError :: CPUError -> Bool
isRecoverableError (ThreadError _) = True
isRecoverableError SIMDNotSupported = True
isRecoverableError BLASNotAvailable = True
isRecoverableError (ArchitectureNotSupported _) = False
isRecoverableError (UnknownCPUError _) = False

-- | Get error severity
errorSeverity :: CPUError -> ErrorSeverity
errorSeverity (ThreadError _) = SeverityError
errorSeverity SIMDNotSupported = SeverityWarning
errorSeverity BLASNotAvailable = SeverityWarning
errorSeverity (ArchitectureNotSupported _) = SeverityCritical
errorSeverity (UnknownCPUError _) = SeverityError