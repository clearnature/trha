{-# LANGUAGE OverloadedStrings #-}

module Core.Tools.Types
  ( Tool(..)
  , ToolName
  , JSONSchema
  ) where

import Data.Dynamic
import Data.Text (Text)

-- | Unique identifier for a tool
type ToolName = String

-- | JSON Schema type (simplified)
type JSONSchema = String

-- | A tool with its metadata and executor
data Tool = Tool
  { toolName        :: ToolName
  , toolDescription :: Text
  , toolSchema      :: JSONSchema
  , toolExecutor    :: Dynamic -> IO Dynamic
  }