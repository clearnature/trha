{-# LANGUAGE ForeignFunctionInterface #-}

-- | AppContainer SID 派生（不需要任何特权）。
--
-- AppContainer 是 Windows 上唯一在**标准用户**权限下可用的强隔离机制：
-- 进程被放进一个带 capability SID（@S-1-15-2-…@）的容器，只能访问显式
-- 授权给该 SID 的资源。
--
-- 与受限令牌路线（T4.2）的对比：
--
--   * 受限令牌：'CreateRestrictedToken' 本身免特权，但**用它启动进程**需要
--     @SE_IMPERSONATE_NAME@ / @SE_ASSIGNPRIMARYTOKEN_NAME@——UAC 过滤后的标准
--     用户令牌两者皆无（实测 ERROR_ACCESS_DENIED 5 / ERROR_PRIVILEGE_NOT_HELD 1314）。
--   * AppContainer：@CreateProcess@ + @SECURITY_CAPABILITIES@ 全程免特权。
--
-- 本模块只负责 SID 派生；进程创建见
-- 'Infrastructure.Sandbox.Win32.Process.spawnAppContainer'，目录授权复用
-- 'Infrastructure.Sandbox.Win32.Acl.grantWriteAccess'。
module Infrastructure.Sandbox.Win32.AppContainer
  ( ContainerSid
  , containerSidRaw
  , AppContainerError(..)
  , deriveContainerSid
  , containerSidText
  , freeContainerSid
  ) where

import Data.Word (Word32)
import Foreign
import Foreign.C.String (CWString, peekCWString, withCWString)
import Foreign.C.Types (CInt(..), CLong(..), CWchar)

-- | AppContainer SID 句柄（由系统分配，必须 'freeContainerSid' 释放）。
newtype ContainerSid = ContainerSid (Ptr ())

-- | 原始 SID 指针（传给 @SECURITY_CAPABILITIES@ 与 ACL 授权）。
containerSidRaw :: ContainerSid -> Ptr ()
containerSidRaw (ContainerSid sid) = sid

data AppContainerError = AppContainerError
  { aceApi  :: String
  , aceCode :: Word32
  }
  deriving (Eq, Show)

-- ── 外部函数 ──────────────────────────────────────────────────────────────
--
-- @DeriveAppContainerSidFromAppContainerName@ 来自 @userenv.dll@，返回 HRESULT。
-- 派生是纯函数式的：不需要预先 @CreateAppContainerProfile@，同一个名字永远
-- 得到同一个 SID——所以目录的 ACE 只需授权一次。

foreign import ccall unsafe "DeriveAppContainerSidFromAppContainerName"
  c_DeriveAppContainerSid :: CWString -> Ptr (Ptr ()) -> IO CLong

foreign import ccall unsafe "ConvertSidToStringSidW"
  c_ConvertSidToStringSidW :: Ptr () -> Ptr (Ptr CWchar) -> IO CInt

foreign import ccall unsafe "FreeSid"
  c_FreeSid :: Ptr () -> IO (Ptr ())

foreign import ccall unsafe "LocalFree"
  c_LocalFree :: Ptr () -> IO (Ptr ())

-- ── 主流程 ────────────────────────────────────────────────────────────────

-- | 由容器名确定性派生 SID（形如 @S-1-15-2-…@）。
deriveContainerSid :: String -> IO (Either AppContainerError ContainerSid)
deriveContainerSid name =
  withCWString name $ \wideName ->
    alloca $ \sidOut -> do
      hr <- c_DeriveAppContainerSid wideName sidOut
      if hr /= 0
        then pure (Left (AppContainerError "DeriveAppContainerSidFromAppContainerName" (fromIntegral hr)))
        else do
          sid <- peek sidOut
          if sid == nullPtr
            then pure (Left (AppContainerError "DeriveAppContainerSidFromAppContainerName" 0))
            else pure (Right (ContainerSid sid))

-- | SID 转字符串（用于 icacls 授权与日志）。
containerSidText :: ContainerSid -> IO (Either AppContainerError String)
containerSidText (ContainerSid sid) =
  alloca $ \strOut -> do
    ok <- c_ConvertSidToStringSidW sid strOut
    if ok == 0
      then pure (Left (AppContainerError "ConvertSidToStringSidW" 0))
      else do
        wide <- peek strOut
        text <- peekCWString wide
        _ <- c_LocalFree (castPtr wide)
        pure (Right text)

-- | 释放 SID。
freeContainerSid :: ContainerSid -> IO ()
freeContainerSid (ContainerSid sid) = () <$ c_FreeSid sid
