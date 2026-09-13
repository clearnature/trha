{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.WebGPU.Error
  ( -- * Error Handling
    WebGPUError(..)
  , errorToText
  , isRecoverableError
  , errorSeverity
  , ErrorSeverity(..)
  ) where

import Infrastructure.WebGPU.Types
import Data.Text (Text)

-- | Error severity
data ErrorSeverity
  = SeverityInfo
  | SeverityWarning
  | SeverityError
  | SeverityCritical
  deriving (Show, Eq, Ord)

-- | Convert error to text
errorToText :: WebGPUError -> Text
errorToText DeviceNotFoundError = "WebGPU device not found"
errorToText (DeviceLostError msg) = "WebGPU device lost: " <> msg
errorToText (ShaderCompilationError msg) = "Shader compilation error: " <> msg
errorToText (PipelineCreationError msg) = "Pipeline creation error: " <> msg
errorToText (BufferCreationError msg) = "Buffer creation error: " <> msg
errorToText (CommandEncoderError msg) = "Command encoder error: " <> msg
errorToText (UnknownWebGPUError msg) = "Unknown WebGPU error: " <> msg

-- | Check if error is recoverable
isRecoverableError :: WebGPUError -> Bool
isRecoverableError DeviceNotFoundError = False
isRecoverableError (DeviceLostError _) = False
isRecoverableError (ShaderCompilationError _) = True
isRecoverableError (PipelineCreationError _) = True
isRecoverableError (BufferCreationError _) = True
isRecoverableError (CommandEncoderError _) = True
isRecoverableError (UnknownWebGPUError _) = False

-- | Get error severity
errorSeverity :: WebGPUError -> ErrorSeverity
errorSeverity DeviceNotFoundError = SeverityCritical
errorSeverity (DeviceLostError _) = SeverityCritical
errorSeverity (ShaderCompilationError _) = SeverityError
errorSeverity (PipelineCreationError _) = SeverityError
errorSeverity (BufferCreationError _) = SeverityWarning
errorSeverity (CommandEncoderError _) = SeverityWarning
errorSeverity (UnknownWebGPUError _) = SeverityError