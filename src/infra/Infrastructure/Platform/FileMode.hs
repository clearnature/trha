{-# LANGUAGE CPP #-}

-- | 跨平台的文件模式 shim。
--
-- POSIX 侧直接用 @System.Posix.Files@ 的 @setFileMode@ 把敏感文件设成 0600。
-- Windows 没有 POSIX mode（权限由 ACL 管，见 @Infrastructure.Sandbox.Win32.Acl@），
-- 所以这里退化成空操作。
--
-- 之所以收口成一个模块：原先 7 个 CLI 模块各自 import @System.Posix.Files@，
-- 在 Windows 上全部编译失败；每处各写一遍 CPP 既重复又容易漏。
module Infrastructure.Platform.FileMode
  ( FileMode
  , setFileMode
  , ownerReadMode
  , ownerWriteMode
  , unionFileModes
  ) where

#ifndef mingw32_HOST_OS
-- FileMode 类型来自 System.Posix.Types（CMode 的别名）；System.Posix.Files
-- 只导出 fileMode / setFileMode 之类的函数，不导出该类型名本身。
-- 这条 import 只在 Linux/macOS 编译，Windows 本地构建看不到它——
-- 正是「CI 只跑根包」时期漏掉的错误。
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import System.Posix.Types (FileMode)
#else
import Data.Bits ((.|.))
import Data.Word (Word32)

-- | Windows 上没有 POSIX mode 类型；用一个整数占位，只为让签名对得上。
type FileMode = Word32

ownerReadMode :: FileMode
ownerReadMode = 0o400

ownerWriteMode :: FileMode
ownerWriteMode = 0o200

unionFileModes :: FileMode -> FileMode -> FileMode
unionFileModes = (.|.)

-- | Windows 的权限是 ACL，不是 POSIX mode；这里空操作。
--
-- 注意：这**不**意味着敏感文件在 Windows 上无保护——调用方若在 Windows 上
-- 需要真正收紧权限，应走 @Win32.Acl.grantWriteAccess@ 那条路。
setFileMode :: FilePath -> FileMode -> IO ()
setFileMode _ _ = pure ()
#endif
