{-# LANGUAGE OverloadedStrings #-}
import Infrastructure.Sandbox.Win32.AppContainer
import Infrastructure.Sandbox.Win32.Process

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
  sidR <- deriveContainerSid "trha-sandbox-test"
  case sidR of
    Left e -> putStrLn ("sid FAIL: " <> show e)
    Right sid -> do
      r1 <- runCmd sid "echo ok > D:/tmp/ac3-ws/out.txt"
      putStrLn ("[1] write workspace  -> " <> r1)
      r2 <- runCmd sid "echo x > C:/Windows/appcontainer-test.txt"
      putStrLn ("[2] write C:/Windows -> " <> r2)
      r3 <- runCmd sid "rmdir /s /q D:/tmp/ac3-ws"
      putStrLn ("[3] rmdir workspace  -> " <> r3)
      freeContainerSid sid
