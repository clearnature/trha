module Core.Tools.Registry
  ( ToolRegistry(..)
  , createToolRegistry
  , registerTool
  , unregisterTool
  , getTool
  , listTools
  ) where

import Core.Tools.Types
import Data.IORef
import qualified Data.Map as Map

-- | Tool registry with scope support
data ToolRegistry = ToolRegistry
  { tools      :: IORef (Map.Map ToolName Tool)
  , toolScopes :: IORef (Map.Map String [ToolName])
  }

-- | Create a new tool registry
createToolRegistry :: IO ToolRegistry
createToolRegistry = do
  toolsRef <- newIORef Map.empty
  scopesRef <- newIORef Map.empty
  return $ ToolRegistry toolsRef scopesRef

-- | Register a tool
registerTool :: ToolRegistry -> Tool -> IO ()
registerTool registry tool = do
  modifyIORef (tools registry) (Map.insert (toolName tool) tool)

-- | Unregister a tool
unregisterTool :: ToolRegistry -> ToolName -> IO ()
unregisterTool registry name = do
  modifyIORef (tools registry) (Map.delete name)

-- | Get a tool by name
getTool :: ToolRegistry -> ToolName -> IO (Maybe Tool)
getTool registry name = do
  toolsMap <- readIORef (tools registry)
  return $ Map.lookup name toolsMap

-- | List all tools
listTools :: ToolRegistry -> IO [Tool]
listTools registry = do
  toolsMap <- readIORef (tools registry)
  return $ Map.elems toolsMap