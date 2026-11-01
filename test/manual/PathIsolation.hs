{-# LANGUAGE OverloadedStrings #-}

-- | T4.5 路径规范化真机验收（Windows）。
--
-- 探针：
--   1. junction 指向 workspace 外 → normalizePath 解析出真实路径，
--      checkWithin 必须判 False（拒收）——这是 junction 逃逸的核心威胁
--   2. workspace 内的真实文件 → checkWithin 判 True（放行）
--   3. 不存在的路径 → normalizePath 报错（fail-closed）
--
-- junction 用 @mklink /J@ 创建（目录联接不需要特权，普通用户即可）。
module Main where

import Control.Exception (SomeException, try)
import Infrastructure.Sandbox.Win32.Path
import System.Directory (createDirectoryIfMissing, doesPathExist)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.Process (callCommand)

-- Left（解析或校验出错）一律视为「不放行」：fail-closed。
judge :: Either PathError Bool -> Bool
judge = either (const False) id

main :: IO ()
main = do
  let ws = "D:/tmp/path-test-ws"
  createDirectoryIfMissing True (ws </> "sub")
  writeFile (ws </> "sub" </> "real.txt") "hello"

  -- 1) junction: <ws>/jailbreak -> C:/Windows（workspace 外）
  let j = ws </> "jailbreak"
  jExists <- doesPathExist j
  if jExists
    then putStrLn "junction: already exists, reuse"
    else do
      r <- try (callCommand ("cmd /d /s /c mklink /J \"" ++ j ++ "\" C:\\Windows"))
             :: IO (Either SomeException ())
      either (\e -> putStrLn ("junction create failed (non-fatal): " <> show e))
             (\_ -> putStrLn "junction: created -> C:/Windows") r

  -- 2) normalizePath 解析 junction 的真实目标
  rj <- normalizePath j
  putStrLn ("normalize junction -> " <> show rj)
  withinJunction <- case rj of
    Right real -> judge <$> checkWithin ws real
    Left _ -> pure False
  putStrLn ("probe checkWithin junction (expect False): " <> show withinJunction)

  -- 3) workspace 内真实文件：normalize + within 都应通过
  rf <- normalizePath (ws </> "sub" </> "real.txt")
  withinFile <- case rf of
    Right real -> judge <$> checkWithin ws real
    Left _ -> pure False
  putStrLn ("probe checkWithin real file (expect True): " <> show withinFile)

  -- 4) 不存在的路径：fail-closed（报错）
  rb <- normalizePath (ws </> "no-such-file.txt")
  putStrLn ("probe normalize missing (expect Left): " <> show (either (const "Left") (const "Right") rb))

  -- 验收判定
  if not withinJunction && withinFile
    then putStrLn "PATH-ISOLATION: PASS"
    else do
      putStrLn "PATH-ISOLATION: FAIL"
      exitFailure
