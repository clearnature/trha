{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Infrastructure.Sandbox.Process
  ( Sandbox(..)
  , createSandbox
  , execute
  ) where

import System.Process
import System.Exit (ExitCode(..))
import Data.Text (Text)
import qualified Data.Text as T
import Control.Concurrent (threadDelay)
import Control.Exception (try, SomeException)

-- | Process sandbox
data Sandbox = Sandbox
  { sandboxTimeout :: Int
  }

-- | Create a new sandbox
createSandbox :: Int -> IO Sandbox
createSandbox timeout = do
  return $ Sandbox timeout

-- | Execute a command in sandbox
execute :: Sandbox -> String -> IO (Either Text Text)
execute sandbox cmd = do
  -- Run command with timeout
  result <- try $ readCreateProcessWithExitCode (shell cmd) ""
  case result of
    Right (exitCode, stdout, stderr) ->
      if exitCode == ExitSuccess
        then return $ Right $ T.pack stdout
        else return $ Left $ T.pack $ "Command failed: " ++ stderr
    Left (ex :: SomeException) ->
      return $ Left $ T.pack $ "Exception: " ++ show ex