{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

-- | 受限令牌创建（T4.2，Haskell FFI）。
--
-- 参考 @deepseek-harness/packages/sandbox/sandbox-windows-acl/src/token.ts@ 的调用序列：
--
-- 1. @OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE)@
-- 2. @ConvertStringSidToSidW@ 把 capability SID 解析成二进制 SID
-- 3. @CreateRestrictedToken(DISABLE_MAX_PRIVILEGE, restricting = [capability SID])@
--
-- == WRITE_RESTRICTED 的语义
--
-- 带 restricting SID 的令牌，其所有写访问只有在目标对象的 DACL 中出现了
-- 「令牌携带的某个 restricting SID」时才被允许。所以令牌必须与 ACL 授权（T4.3）
-- 配套：ACL 给 capability SID 放行，令牌带着它才能写。
--
-- == 已知限制
--
-- 创建令牌本身不需要特权，但**用该令牌启动子进程**需要
-- @SE_IMPERSONATE_NAME@ / @SE_ASSIGNPRIMARYTOKEN_NAME@ / @SE_INCREASE_QUOTA_NAME@
-- ——UAC 过滤后的标准用户令牌三者皆无。因此主线改用 AppContainer，
-- 本模块保留供将来以管理员身份运行 helper 时使用。
module Infrastructure.Sandbox.Win32.Token
  ( RestrictedToken
  , tokenHandle
  , TokenError(..)
  , createRestrictedToken
  , releaseRestrictedToken
  ) where

import Control.Exception (bracket)
import Data.Bits ((.|.))
import Data.Word (Word32)
import Foreign
import Foreign.C.String (CWString, withCWString)
import Foreign.C.Types (CInt(..))

-- ── Win32 基础类型 ─────────────────────────────────────────────────────────

type Handle = Ptr ()
type Bool32 = CInt
type Dword = Word32

-- | @DISABLE_MAX_PRIVILEGE@：清空除 @SeChangeNotifyPrivilege@ 外的全部特权。
disableMaxPrivilege :: Dword
disableMaxPrivilege = 0x00000001

tokenQuery :: Dword
tokenQuery = 0x0008

tokenDuplicate :: Dword
tokenDuplicate = 0x0002

-- | @SID_AND_ATTRIBUTES@（x64 布局：8 字节 SID 指针 + 4 字节属性 + 4 字节填充）。
data SidAndAttributes = SidAndAttributes
  { saaSid        :: Ptr ()
  , saaAttributes :: Dword
  }

instance Storable SidAndAttributes where
  sizeOf _ = 16
  alignment _ = 8
  peek ptr = SidAndAttributes
    <$> peekByteOff ptr 0
    <*> peekByteOff ptr 8
  poke ptr v = do
    pokeByteOff ptr 0 (saaSid v)
    pokeByteOff ptr 8 (saaAttributes v)

-- ── 外部函数 ──────────────────────────────────────────────────────────────

foreign import ccall unsafe "CreateRestrictedToken"
  c_CreateRestrictedToken
    :: Handle -> Dword -> Dword -> Ptr SidAndAttributes
    -> Dword -> Ptr () -> Dword -> Ptr SidAndAttributes
    -> Ptr Handle -> IO Bool32

foreign import ccall unsafe "OpenProcessToken"
  c_OpenProcessToken :: Handle -> Dword -> Ptr Handle -> IO Bool32

foreign import ccall unsafe "GetCurrentProcess"
  c_GetCurrentProcess :: IO Handle

foreign import ccall unsafe "ConvertStringSidToSidW"
  c_ConvertStringSidToSidW :: CWString -> Ptr (Ptr ()) -> IO Bool32

foreign import ccall unsafe "CloseHandle"
  c_CloseHandle :: Handle -> IO Bool32

foreign import ccall unsafe "LocalFree"
  c_LocalFree :: Ptr () -> IO (Ptr ())

foreign import ccall unsafe "GetLastError"
  c_getLastError :: IO Dword

-- ── 封装 ──────────────────────────────────────────────────────────────────

newtype RestrictedToken = RestrictedToken Handle

-- | 原始令牌句柄（供 @CreateProcessAsUser@ 使用）。
tokenHandle :: RestrictedToken -> Handle
tokenHandle (RestrictedToken h) = h

instance Show RestrictedToken where
  show (RestrictedToken h) = "RestrictedToken " <> show h

-- | 失败时携带 API 名与 Win32 错误码——绝不静默降级为「不受限运行」。
data TokenError = TokenError
  { teApi  :: String
  , teCode :: Maybe Dword
  }
  deriving (Eq, Show)

lastWin32Error :: IO Dword
lastWin32Error = c_getLastError

-- | 用 capability SID 作为唯一 restricting SID 创建受限令牌。
createRestrictedToken :: String -> IO (Either TokenError RestrictedToken)
createRestrictedToken capabilitySid =
  withCWString capabilitySid $ \wideSid ->
    alloca $ \sidOut -> do
      okSid <- c_ConvertStringSidToSidW wideSid sidOut
      if okSid == 0
        then Left <$> (TokenError "ConvertStringSidToSidW" . Just <$> lastWin32Error)
        else do
          sid <- peek sidOut
          bracket openBaseToken closeBaseToken $ \mBase -> case mBase of
            Left e -> pure (Left e)
            Right base -> do
              res <- withSidRestriction sid base
              _ <- c_LocalFree sid
              pure res

openBaseToken :: IO (Either TokenError Handle)
openBaseToken = alloca $ \out -> do
  proc <- c_GetCurrentProcess
  ok <- c_OpenProcessToken proc (tokenQuery .|. tokenDuplicate) out
  if ok == 0
    then Left <$> (TokenError "OpenProcessToken" . Just <$> lastWin32Error)
    else Right <$> peek out

closeBaseToken :: Either TokenError Handle -> IO ()
closeBaseToken (Left _) = pure ()
closeBaseToken (Right h) = () <$ c_CloseHandle h

withSidRestriction :: Ptr () -> Handle -> IO (Either TokenError RestrictedToken)
withSidRestriction sid base = alloca $ \newTokenOut ->
  allocaArray 1 $ \restrictArr -> do
    pokeElemOff restrictArr 0 (SidAndAttributes sid 0)
    ok <- c_CreateRestrictedToken
      base
      disableMaxPrivilege
      0
      nullPtr
      0
      nullPtr
      1
      restrictArr
      newTokenOut
    if ok == 0
      then Left <$> (TokenError "CreateRestrictedToken" . Just <$> lastWin32Error)
      else Right . RestrictedToken <$> peek newTokenOut

-- | 释放受限令牌句柄。
releaseRestrictedToken :: RestrictedToken -> IO ()
releaseRestrictedToken (RestrictedToken h) = () <$ c_CloseHandle h
