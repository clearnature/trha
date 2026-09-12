{-# LANGUAGE OverloadedStrings #-}

-- | Stub kernel entry point (K6): serves the OpenAI-compatible API with a
-- deterministic two-round tool loop, letting the orchestration layer
-- exercise real tool execution without a DeepSeek API key.
module Main (main) where

import API.Server (startStubKernel)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  port <- case args of
    (p : _) -> case reads p of
      [(n, "")] -> return n
      _         -> die "usage: trha-kernel-stub PORT"
    [] -> return 8080
  startStubKernel port
