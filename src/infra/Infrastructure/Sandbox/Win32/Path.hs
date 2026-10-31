{-# LANGUAGE ForeignFunctionInterface #-}

-- | 路径规范化：把任意路径（含 junction、8.3 短名）解析成卷上的真实路径。
--
-- T4.5 的动机：AppContainer 的目录授权按路径字符串下发，而 junction 可以让一个
-- 「看起来在 workspace 里」的路径实际指向外部。'normalizePath' 调
-- @GetFinalPathNameByHandleW@ 让**内核**给出解析后的真实路径，调用方比对前缀
-- 即可拒绝这类逃逸。
--
-- 替代数据流（ADS，@file.txt:stream@）：'CreateFileW' 会打开流本身，返回的
-- 路径仍是宿主文件，因此 ADS 不会把文件「挪到」workspace 之外。
module Infrastructure.Sandbox.Win32.Path
  ( PathError(..)
  , normalizePath
  , checkWithin
  , isUnderNormalized
  , stripLongPathPrefix
  ) where

import Data.Char (toLower)
import Data.Word (Word32)
import Foreign
import Foreign.C.String (CWString, peekCWStringLen, withCWString)
import Foreign.C.Types (CWchar, CInt(..))
import System.FilePath (addTrailingPathSeparator, normalise)

type Handle = Ptr ()
type Dword  = Word32
type Bool32 = CInt

data PathError = PathError
  { peApi  :: String
  , peCode :: Word32
  } deriving (Eq, Show)

-- 打开已存在的目录/文件，只要读：GENERIC_READ + 全共享 + OPEN_EXISTING +
-- FILE_FLAG_BACKUP_SEMANTICS（缺最后一个标志时 CreateFileW 打不开目录）。
genericRead :: Dword
genericRead = 0x80000000

shareAll :: Dword
shareAll = 0x00000007

openExisting :: Dword
openExisting = 3

backupSemantics :: Dword
backupSemantics = 0x02000000

iNVALID_HANDLE_VALUE :: Handle
iNVALID_HANDLE_VALUE = intPtrToPtr (-1)

foreign import ccall unsafe "CreateFileW"
  c_CreateFileW
    :: CWString -> Dword -> Dword -> Ptr () -> Dword -> Dword -> Ptr ()
    -> IO Handle

foreign import ccall unsafe "GetFinalPathNameByHandleW"
  c_GetFinalPathNameByHandleW :: Handle -> Ptr CWchar -> Dword -> Dword -> IO Dword

foreign import ccall unsafe "CloseHandle"
  c_CloseHandle :: Handle -> IO Bool32

foreign import ccall unsafe "GetLastError"
  c_GetLastError :: IO Dword

mkErr :: String -> IO PathError
mkErr api = PathError api <$> c_GetLastError

-- | 解析成真实路径。返回值已去掉 @\\\\?\\@ 长路径前缀。
--
-- 失败（不存在、无权限）一律返回 'Left'——调用方不得把它当作「无逃逸」继续执行。
normalizePath :: FilePath -> IO (Either PathError FilePath)
normalizePath path =
  withCWString path $ \widePath -> do
    h <- c_CreateFileW widePath genericRead shareAll nullPtr openExisting
           backupSemantics nullPtr
    if h == iNVALID_HANDLE_VALUE
      then Left <$> mkErr "CreateFileW"
      else do
        r <- allocaArray bufChars $ \buf -> do
          n <- c_GetFinalPathNameByHandleW h buf (fromIntegral bufChars) 0
          if n == 0
            then Left <$> mkErr "GetFinalPathNameByHandleW"
            else Right . stripLongPathPrefix <$> peekCWStringLen (buf, fromIntegral n)
        _ <- c_CloseHandle h
        pure r
  where
    -- 32768 = MAX_PATH 的长路径上限量级，足够覆盖本项目的 workspace 路径。
    bufChars = 32768 :: Int

-- | 去掉 @\\\\?\\@ 与 @\\\\?\\UNC\\@ 前缀，其余原样返回。
stripLongPathPrefix :: FilePath -> FilePath
stripLongPathPrefix p
  | hasPrefix "\\\\?\\UNC\\" = "\\\\" <> drop 8 p
  | hasPrefix "\\\\?\\" = drop 4 p
  | otherwise = p
  where
    hasPrefix prefix = take (length prefix) p == prefix

-- | 把 @path@ 规范化后判断它是否仍在 @root@ 之内。
--
-- junction（目录联接）、8.3 短名、长路径前缀都在这一步被内核解开。解析失败一律
-- 返回 'Left'（fail-closed）——调用方不得把「解析不出来」当成「没逃逸」。
checkWithin :: FilePath -> FilePath -> IO (Either PathError Bool)
checkWithin root path = do
  rootR <- normalizePath root
  case rootR of
    Left e -> pure (Left e)
    Right rootN -> do
      pathR <- normalizePath path
      case pathR of
        Left e -> pure (Left e)
        Right pathN -> pure (Right (isUnderNormalized rootN pathN))

-- | 对**已规范化**的路径做前缀判断。Windows 大小写不敏感，所以统一折叠后比较。
isUnderNormalized :: FilePath -> FilePath -> Bool
isUnderNormalized root path =
  p == r || hasPrefix (addTrailingPathSeparator r) p
  where
    norm = map toLower . normalise
    r = dropTrailingSep (norm root)
    p = norm path
    hasPrefix prefix s = take (length prefix) s == prefix
    dropTrailingSep s
      | not (null s) && last s == '\\' = init s
      | otherwise = s
