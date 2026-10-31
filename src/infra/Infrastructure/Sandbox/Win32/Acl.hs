{-# LANGUAGE ForeignFunctionInterface #-}

-- | ACL 授权（T4.3，Haskell FFI）。
--
-- 给 workspace 树授权 capability SID 的写权限，并在同一次
-- @SetNamedSecurityInfoW@ 里追加两件事：
--
--   1. world SID 的 @DENY FILE_DELETE_CHILD@（防 rename/delete 逃逸）
--   2. capability SID 的 @GRANT_ACCESS@（写 + 删 + 删子项）
--
-- 读-合并-写：直接 @SetEntriesInAclW(OldAcl = NULL)@ 会从零构建 DACL，
-- 丢弃目录原有的全部 ACE（管理员、SYSTEM 的），那是不可接受的破坏。
module Infrastructure.Sandbox.Win32.Acl
  ( AclError(..)
  , grantWriteAccess
  , applyLowLabel
  , renderAclError
  ) where

import Data.Bits ((.&.), (.|.), complement)
import Data.Word (Word32)
import Foreign
import Foreign.C.String (CWString, withCWString)
import Foreign.C.Types (CInt(..))

type Dword = Word32

-- ── 常量 ──────────────────────────────────────────────────────────────────

-- | @FILE_GENERIC_WRITE@
fileGenericWrite :: Dword
fileGenericWrite = 0x00120116

-- | @FILE_DELETE_CHILD@
fileDeleteChild :: Dword
fileDeleteChild = 0x0040

-- | @DELETE@（标准删除权）
deleteAccess :: Dword
deleteAccess = 0x00010000

-- | @STANDARD_RIGHTS_WRITE@：必须从掩码里排除。
standardRightsWrite :: Dword
standardRightsWrite = 0x001F0000

-- | 授予的访问掩码。
grantMask :: Dword
grantMask =
  (fileGenericWrite .|. deleteAccess .|. fileDeleteChild)
    .&. complement standardRightsWrite

daclSecurityInformation :: Dword
daclSecurityInformation = 0x00000004

labelSecurityInformation :: Dword
labelSecurityInformation = 0x00000010

seFileObject :: Dword
seFileObject = 1

grantAccess :: Dword
grantAccess = 1

denyAccess :: Dword
denyAccess = 3

subContainersAndObjectsInherit :: Dword
subContainersAndObjectsInherit = 0x3

-- | @FILE_DELETE_CHILD@ 对文件无意义，deny 只继承到容器。
subContainersOnlyInherit :: Dword
subContainersOnlyInherit = 0x2

-- | World SID（Everyone）：ambient-delete deny 的作用对象。
worldSid :: String
worldSid = "S-1-1-0"

-- | Low 完整性 SID。
lowIntegritySid :: String
lowIntegritySid = "S-1-16-4096"

-- | @SYSTEM_MANDATORY_LABEL_NO_WRITE_UP@
noWriteUp :: Dword
noWriteUp = 0x00000001

aclRevision :: Dword
aclRevision = 2

zeroDword :: Dword
zeroDword = 0

errorSuccess :: Dword
errorSuccess = 0

-- ── EXPLICIT_ACCESS_W（48 字节）────────────────────────────────────────────
--
-- 布局（x64）：perms@0, mode@4, inheritance@8, pad@12,
-- pMultipleTrustee@16, MultipleTrusteeOperation@24,
-- TrusteeForm@28, TrusteeType@32, pad@36, ptstrName@40。
data ExplicitAccessW = ExplicitAccessW
  { eaPermissions :: Dword
  , eaMode        :: Dword
  , eaInheritance :: Dword
  , eaTrusteeForm :: Dword
  , eaTrusteeType :: Dword
  , eaTrusteeName :: Ptr ()
  }

instance Storable ExplicitAccessW where
  sizeOf _ = 48
  alignment _ = 8
  peek ptr = ExplicitAccessW
    <$> peekByteOff ptr 0
    <*> peekByteOff ptr 4
    <*> peekByteOff ptr 8
    <*> peekByteOff ptr 28
    <*> peekByteOff ptr 32
    <*> peekByteOff ptr 40
  poke ptr v = do
    pokeByteOff ptr 0 (eaPermissions v)
    pokeByteOff ptr 4 (eaMode v)
    pokeByteOff ptr 8 (eaInheritance v)
    fillBytes (ptr `plusPtr` 12) 0 4
    pokeByteOff ptr 16 (nullPtr :: Ptr ())
    pokeByteOff ptr 24 zeroDword
    pokeByteOff ptr 28 (eaTrusteeForm v)
    pokeByteOff ptr 32 (eaTrusteeType v)
    fillBytes (ptr `plusPtr` 36) 0 4
    pokeByteOff ptr 40 (eaTrusteeName v)

-- ── 外部函数 ──────────────────────────────────────────────────────────────

foreign import ccall unsafe "ConvertStringSidToSidW"
  c_ConvertStringSidToSidW :: CWString -> Ptr (Ptr ()) -> IO CInt

foreign import ccall unsafe "GetNamedSecurityInfoW"
  c_GetNamedSecurityInfoW
    :: CWString -> Dword -> Dword
    -> Ptr (Ptr ()) -> Ptr (Ptr ()) -> Ptr (Ptr ()) -> Ptr (Ptr ()) -> Ptr (Ptr ())
    -> IO Dword

foreign import ccall unsafe "SetEntriesInAclW"
  c_SetEntriesInAclW :: Dword -> Ptr ExplicitAccessW -> Ptr () -> Ptr (Ptr ()) -> IO Dword

foreign import ccall unsafe "SetNamedSecurityInfoW"
  c_SetNamedSecurityInfoW
    :: CWString -> Dword -> Dword
    -> Ptr () -> Ptr () -> Ptr () -> Ptr ()
    -> IO Dword

foreign import ccall unsafe "InitializeAcl"
  c_InitializeAcl :: Ptr () -> Dword -> Dword -> IO CInt

foreign import ccall unsafe "AddMandatoryAce"
  c_AddMandatoryAce :: Ptr () -> Dword -> Dword -> Dword -> Ptr () -> IO CInt

foreign import ccall unsafe "LocalFree"
  c_LocalFree :: Ptr () -> IO (Ptr ())

foreign import ccall unsafe "GetLastError"
  c_getLastError :: IO Dword

-- ── 错误类型 ──────────────────────────────────────────────────────────────

data AclError = AclError
  { aeApi  :: String
  , aeCode :: Word32
  , aePath :: FilePath
  }
  deriving (Eq, Show)

renderAclError :: AclError -> String
renderAclError e =
  aeApi e <> " failed (Win32 " <> show (aeCode e) <> ") on " <> aePath e

mkErr :: String -> FilePath -> IO AclError
mkErr api path = do
  code <- c_getLastError
  pure (AclError api code path)

mkErrWith :: String -> Dword -> FilePath -> IO AclError
mkErrWith api code path = pure (AclError api code path)

-- ── 主流程 ────────────────────────────────────────────────────────────────

-- | 给一个目录授权 capability SID 的写权限（读-合并-写）。
--
-- 失败返回 @Left@，调用方必须把它当作「不可运行」——不得回退到无限制执行。
grantWriteAccess :: FilePath -> String -> IO (Either AclError ())
grantWriteAccess path capabilitySid =
  withCWString capabilitySid $ \wideSid ->
    withCWString worldSid $ \wideWorld ->
      withCWString path $ \widePath ->
        alloca $ \sidOut -> alloca $ \worldOut -> do
          okSid <- c_ConvertStringSidToSidW wideSid sidOut
          okWorld <- c_ConvertStringSidToSidW wideWorld worldOut
          if okSid == 0 || okWorld == 0
            then Left <$> mkErr "ConvertStringSidToSidW" path
            else do
              capabilitySidPtr <- peek sidOut
              worldSidPtr <- peek worldOut
              result <- applyGrant widePath capabilitySidPtr worldSidPtr path
              _ <- c_LocalFree capabilitySidPtr
              _ <- c_LocalFree worldSidPtr
              pure result

applyGrant :: CWString -> Ptr () -> Ptr () -> FilePath -> IO (Either AclError ())
applyGrant widePath capabilitySidPtr worldSidPtr path =
  alloca $ \ownerOut -> alloca $ \groupOut -> alloca $ \daclOut ->
    alloca $ \saclOut -> alloca $ \sdOut -> do
      rc <- c_GetNamedSecurityInfoW
        widePath seFileObject daclSecurityInformation ownerOut groupOut daclOut saclOut sdOut
      if rc /= errorSuccess
        then Left <$> mkErrWith "GetNamedSecurityInfoW" rc path
        else do
          securityDescriptor <- peek sdOut
          oldDacl <- peek daclOut
          merged <- mergeAce capabilitySidPtr worldSidPtr oldDacl path
          _ <- c_LocalFree securityDescriptor
          pure merged

mergeAce :: Ptr () -> Ptr () -> Ptr () -> FilePath -> IO (Either AclError ())
mergeAce capabilitySidPtr worldSidPtr oldDacl path =
  allocaArray 2 $ \entriesOut -> alloca $ \newAclOut -> do
    -- 1) capability SID：授予写权限（可继承到子项）
    pokeElemOff entriesOut 0
      (ExplicitAccessW grantMask grantAccess subContainersAndObjectsInherit
        zeroDword zeroDword capabilitySidPtr)
    -- 2) world SID：deny FILE_DELETE_CHILD（只继承到容器）
    pokeElemOff entriesOut 1
      (ExplicitAccessW fileDeleteChild denyAccess subContainersOnlyInherit
        zeroDword zeroDword worldSidPtr)
    rc <- c_SetEntriesInAclW 2 entriesOut oldDacl newAclOut
    if rc /= errorSuccess
      then Left <$> mkErrWith "SetEntriesInAclW" rc path
      else do
        newAcl <- peek newAclOut
        withCWString path $ \widePath -> do
          applyRc <- c_SetNamedSecurityInfoW
            widePath seFileObject daclSecurityInformation
            nullPtr nullPtr newAcl nullPtr
          _ <- c_LocalFree newAcl
          if applyRc /= errorSuccess
            then Left <$> mkErrWith "SetNamedSecurityInfoW" applyRc path
            else pure (Right ())

-- ── Low 完整性标签 ────────────────────────────────────────────────────────

-- | 给目录加 Low 完整性标签（需要 @SE_SECURITY_NAME@ 特权）。
--
-- 无特权时返回 @ERROR_ACCESS_DENIED(5)@ → @Left@：这是设计好的降级路径，
-- 调用方应把它当作 enforcement=partial，而不是拒绝运行。
applyLowLabel :: FilePath -> IO (Either AclError ())
applyLowLabel path =
  withCWString lowIntegritySid $ \wideSid ->
    withCWString path $ \widePath ->
      alloca $ \sidOut -> do
        okSid <- c_ConvertStringSidToSidW wideSid sidOut
        if okSid == 0
          then Left <$> mkErr "ConvertStringSidToSidW" path
          else do
            sid <- peek sidOut
            let aclSizeBytes = 128 :: Int
                aclSizeDword = fromIntegral aclSizeBytes :: Dword
            allocaBytes aclSizeBytes $ \acl -> do
              okInit <- c_InitializeAcl acl aclSizeDword aclRevision
              if okInit == 0
                then do
                  _ <- c_LocalFree sid
                  Left <$> mkErr "InitializeAcl" path
                else do
                  okAce <- c_AddMandatoryAce acl aclRevision 0 noWriteUp sid
                  _ <- c_LocalFree sid
                  if okAce == 0
                    then Left <$> mkErr "AddMandatoryAce" path
                    else do
                      rc <- c_SetNamedSecurityInfoW
                        widePath seFileObject labelSecurityInformation
                        nullPtr nullPtr nullPtr acl
                      if rc /= errorSuccess
                        then Left <$> mkErrWith "SetNamedSecurityInfoW(label)" rc path
                        else pure (Right ())
