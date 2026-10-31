{-# LANGUAGE OverloadedStrings #-}

-- | AppContainer 隔离验收三探针。
--
-- 期望结果（任一不符即说明隔离失效）：
--
--   1. 写 workspace        → 退出码 0（授权路径可写）
--   2. 写 C:\Windows       → 退出码非 0（未授权路径拒绝）
--   3. 删 workspace 根     → 退出码非 0（Everyone deny FILE_DELETE_CHILD）
--
-- workspace 由环境变量 @TRHA_PROBE_WS@ 指定（CI 用 @$RUNNER_TEMP@ 下的一次性
-- 目录）；缺省 @D:/tmp/ac3-ws@ 是本机手工验证用的路径。
module Main (main) where

import Infrastructure.Sandbox.Win32.AppContainer
import Infrastructure.Sandbox.Win32.Process
import System.Environment (lookupEnv)

runCmd :: ContainerSid -> String -> IO String
runCmd sid commandLine = do
  r <- spawnAppContainer sid "C:/Windows/System32/cmd.exe" ["/c", commandLine] "C:/Windows/System32"
  case r of
    Left e -> pure ("spawn FAIL: " <> show e)
    Right sp -> do
      _ <- resumeThread sp
      w <- waitForProcess sp
      closeSpawned sp
      pure (either show show w)

main :: IO ()
main = do
  ws <- maybe "D:/tmp/ac3-ws" id <$> lookupEnv "TRHA_PROBE_WS"
  putStrLn ("workspace: " <> ws)
  sidR <- deriveContainerSid "trha-sandbox-test"
  case sidR of
    Left e -> putStrLn ("sid FAIL: " <> show e)
    Right sid -> do
      r1 <- runCmd sid ("echo ok > " <> ws <> "/out.txt")
      putStrLn ("[1] write workspace  -> " <> r1)
      r2 <- runCmd sid "echo x > C:/Windows/appcontainer-test.txt"
      putStrLn ("[2] write C:/Windows -> " <> r2)
      r3 <- runCmd sid ("rmdir /s /q " <> ws)
      putStrLn ("[3] rmdir workspace  -> " <> r3)
      freeContainerSid sid
