module Infrastructure.Sandbox.Process
  ( Sandbox(..)
  , createSandbox
  , execute
  ) where

import System.Process
import Data.Text (Text)
import qualified Data.Text as T

-- | Process sandbox
data Sandbox = Sandbox
  { sandboxTimeout :: Int
  }

-- | Create a new sandbox
createSandbox :: Int -> IO Sandbox
createSandbox timeout = do
  return $ Sandbox timeout

-- | Execute a command in sandbox (placeholder)
execute :: Sandbox -> String -> IO Text
execute sandbox cmd = do
  -- Placeholder: in real implementation, run in isolated process
  return $ T.pack "Executed: " <> T.pack cmd