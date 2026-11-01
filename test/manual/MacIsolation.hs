{-# LANGUAGE OverloadedStrings #-}

-- | macOS（Seatbelt / sandbox-exec）真机探针 —— T3.x 验收，与 Windows 的
-- @test/manual/AppContainerIsolation.hs@ 同一模式。
--
-- 三探针（profile 由 'sbplProfile' 按 WorkspaceWrite 策略生成）：
--
--   1. @write-workspace@：写 writable 根内文件 → 必须成功
--   2. @write-outside@：写 $HOME 下文件 → 必须被 @(deny file-write*)@ 拒绝
--   3. @network-off@：curl 外网 → 必须被 @(deny network*)@ 拒绝
--
-- 历史教训（写进 Mac.hs 注释）：SBPL 首条匹配优先，allow 必须先于 blanket
-- deny；sandbox-exec 没有 @--@ 分隔符，-p profile 后直接跟命令。
--
-- 仅 macOS 可运行（依赖 sandbox-exec）；类型检查跨平台，CI 的
-- sandbox-macos.yml 负责真机执行。
module Main where

import qualified Data.Text as T
import Infrastructure.Sandbox.Backend.Mac (sbplProfile)
import Infrastructure.Sandbox.Policy (NetworkPolicy(..))
import System.Directory (createDirectoryIfMissing, getHomeDirectory, removeDirectoryRecursive)
import System.Exit (ExitCode(..), exitFailure)
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

data Expect = WantSuccess | WantFailure deriving (Eq, Show)

data Probe = Probe
  { pName :: String
  , pCmd  :: String
  , pWant :: Expect
  }

main :: IO ()
main = do
  home <- getHomeDirectory
  let ws = home </> ".trha-sandbox-mac-probe"
      -- WorkspaceWrite(wrRoot=ws)：allow ws 子路径 + /tmp + /dev/null，
      -- 其余写 deny；网络关（探针 3 的前提）。
      profile = T.unpack (sbplProfile [(ws, True)] [] NetworkOff)
      runCmd cmd = readProcessWithExitCode "sandbox-exec" ["-p", profile, "/bin/sh", "-c", cmd] ""
      probes =
        [ Probe "write-workspace" ("echo probe > " ++ ws ++ "/probe.txt") WantSuccess
        , Probe "write-outside"   "echo probe > \"$HOME/trha-escape-probe\"" WantFailure
        , Probe "network-off"     "curl -m 3 -sS https://example.com -o /dev/null" WantFailure
        ]
  createDirectoryIfMissing True ws
  results <- mapM (runProbe runCmd) probes
  removeDirectoryRecursive ws
  mapM_ print results
  if all prOk results
    then putStrLn "MAC-ISOLATION: PASS"
    else do
      putStrLn "MAC-ISOLATION: FAIL"
      exitFailure

data ProbeResult = ProbeResult
  { prName :: String
  , prOk   :: Bool
  , prNote :: String
  }

instance Show ProbeResult where
  show r = prName r ++ " -> " ++ (if prOk r then "0" else "1")
             ++ "  (" ++ prNote r ++ ")"

runProbe :: (String -> IO (ExitCode, String, String)) -> Probe -> IO ProbeResult
runProbe runCmd p = do
  (code, _out, err) <- runCmd (pCmd p)
  let succeeded = case code of
        ExitSuccess -> True
        ExitFailure _ -> False
      ok = succeeded == (pWant p == WantSuccess)
      note = case code of
        ExitSuccess -> "exit 0"
        ExitFailure n -> "exit " ++ show n ++ if null err then "" else ": " ++ take 120 err
  pure ProbeResult { prName = pName p, prOk = ok, prNote = note }
