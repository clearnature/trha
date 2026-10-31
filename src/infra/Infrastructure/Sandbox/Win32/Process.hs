{-# LANGUAGE ForeignFunctionInterface #-}

-- | 进程创建：受限令牌、普通、AppContainer 三条路径。
--
--   * 'spawnRestricted'：受限令牌 + @CreateProcessAsUserW@——**需要 SE_\* 特权**，
--     UAC 过滤后的标准用户不可用（实测 5 / 1314），保留供提权场景。
--   * 'spawnPlain'：无令牌，无需任何特权，用于 Job 验证与非隔离场景。
--   * 'spawnAppContainer'：@CreateProcess@ + @SECURITY_CAPABILITIES@，**全程免特权**。
--
-- 三者都返回**挂起**（@CREATE_SUSPENDED@）的进程，调用方应先 'assignToJob' 再
-- 'resumeThread'，以消除逃逸窗口。
module Infrastructure.Sandbox.Win32.Process
  ( SpawnedProcess(..)
  , ProcessError(..)
  , spawnRestricted
  , spawnPlain
  , spawnAppContainer
  , resumeThread
  , waitForProcess
  , terminateProcess
  , closeSpawned
  , readPipeChunks
  ) where

import Data.Bits ((.|.))
import Data.Word (Word8, Word16, Word32, Word64)
import Foreign
import Foreign.C.String (CWString, withCWString)
import Foreign.C.Types (CInt(..))
import Infrastructure.Sandbox.Win32.AppContainer (ContainerSid, containerSidRaw)
import Infrastructure.Sandbox.Win32.Token (RestrictedToken, tokenHandle)

type Handle = Ptr ()
type Dword  = Word32
type Bool32 = CInt

-- ── 常量 ──────────────────────────────────────────────────────────────────

createSuspended :: Dword
createSuspended = 0x00000004

createNoWindow :: Dword
createNoWindow = 0x08000000

-- | @EXTENDED_STARTUPINFO_PRESENT@：让 CreateProcess 读 @STARTUPINFOEXW@。
extendedStartupInfoPresent :: Dword
extendedStartupInfoPresent = 0x00080000

-- | @CREATE_UNICODE_ENVIRONMENT@：@lpEnvironment@ 按 UTF-16 解释。
createUnicodeEnvironment :: Dword
createUnicodeEnvironment = 0x00000400

-- | @PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES@
procThreadAttributeSecurityCapabilities :: Word64
procThreadAttributeSecurityCapabilities = 0x00020009

startfUseStdHandles :: Dword
startfUseStdHandles = 0x00000100

startfUseShowWindow :: Dword
startfUseShowWindow = 0x00000001

swHide :: Word16
swHide = 0

handleFlagInherit :: Dword
handleFlagInherit = 0x00000001

waitObject0 :: Dword
waitObject0 = 0x00000000

infinite :: Dword
infinite = 0xFFFFFFFF

-- ── STARTUPINFOW（x64：104 字节）──────────────────────────────────────────
data StartupInfoW = StartupInfoW
  { siFlags      :: Dword
  , siShowWindow :: Word16
  , siStdInput   :: Handle
  , siStdOutput  :: Handle
  , siStdError   :: Handle
  }

startupInfoWSize :: Int
startupInfoWSize = 104

instance Storable StartupInfoW where
  sizeOf _ = startupInfoWSize
  alignment _ = 8
  peek ptr = StartupInfoW
    <$> peekByteOff ptr 60
    <*> peekByteOff ptr 64
    <*> peekByteOff ptr 80
    <*> peekByteOff ptr 88
    <*> peekByteOff ptr 96
  poke ptr v = do
    fillBytes ptr 0 startupInfoWSize
    pokeByteOff ptr 0 (fromIntegral startupInfoWSize :: Dword)
    pokeByteOff ptr 60 (siFlags v)
    pokeByteOff ptr 64 (siShowWindow v)
    pokeByteOff ptr 80 (siStdInput v)
    pokeByteOff ptr 88 (siStdOutput v)
    pokeByteOff ptr 96 (siStdError v)

-- ── STARTUPINFOEXW（x64：112 字节）────────────────────────────────────────
data StartupInfoExW = StartupInfoExW
  { siexFlags         :: Dword
  , siexShowWindow    :: Word16
  , siexStdInput      :: Handle
  , siexStdOutput     :: Handle
  , siexStdError      :: Handle
  , siexAttributeList :: Ptr ()
  }

startupInfoExWSize :: Int
startupInfoExWSize = 112

instance Storable StartupInfoExW where
  sizeOf _ = startupInfoExWSize
  alignment _ = 8
  peek ptr = StartupInfoExW
    <$> peekByteOff ptr 60
    <*> peekByteOff ptr 64
    <*> peekByteOff ptr 80
    <*> peekByteOff ptr 88
    <*> peekByteOff ptr 96
    <*> peekByteOff ptr 104
  poke ptr v = do
    fillBytes ptr 0 startupInfoExWSize
    pokeByteOff ptr 0 (fromIntegral startupInfoExWSize :: Dword)
    pokeByteOff ptr 60 (siexFlags v)
    pokeByteOff ptr 64 (siexShowWindow v)
    pokeByteOff ptr 80 (siexStdInput v)
    pokeByteOff ptr 88 (siexStdOutput v)
    pokeByteOff ptr 96 (siexStdError v)
    pokeByteOff ptr 104 (siexAttributeList v)

-- ── SECURITY_CAPABILITIES（x64：24 字节）──────────────────────────────────
data SecurityCapabilities = SecurityCapabilities
  { scAppContainerSid :: Ptr ()
  , scCapabilities    :: Ptr ()
  , scCapabilityCount :: Dword
  , scReserved        :: Dword
  }

securityCapabilitiesSize :: Int
securityCapabilitiesSize = 24

instance Storable SecurityCapabilities where
  sizeOf _ = securityCapabilitiesSize
  alignment _ = 8
  peek ptr = SecurityCapabilities
    <$> peekByteOff ptr 0
    <*> peekByteOff ptr 8
    <*> peekByteOff ptr 16
    <*> peekByteOff ptr 20
  poke ptr v = do
    pokeByteOff ptr 0 (scAppContainerSid v)
    pokeByteOff ptr 8 (scCapabilities v)
    pokeByteOff ptr 16 (scCapabilityCount v)
    pokeByteOff ptr 20 (scReserved v)

-- ── PROCESS_INFORMATION（x64：24 字节）────────────────────────────────────
data ProcessInfo = ProcessInfo
  { piProcess :: Handle
  , piThread  :: Handle
  , piPid     :: Dword
  , piTid     :: Dword
  }

instance Storable ProcessInfo where
  sizeOf _ = 24
  alignment _ = 8
  peek ptr = ProcessInfo
    <$> peekByteOff ptr 0
    <*> peekByteOff ptr 8
    <*> peekByteOff ptr 16
    <*> peekByteOff ptr 20
  poke ptr v = do
    pokeByteOff ptr 0 (piProcess v)
    pokeByteOff ptr 8 (piThread v)
    pokeByteOff ptr 16 (piPid v)
    pokeByteOff ptr 20 (piTid v)

-- ── 外部函数 ──────────────────────────────────────────────────────────────

foreign import ccall unsafe "CreatePipe"
  c_CreatePipe :: Ptr Handle -> Ptr Handle -> Ptr () -> Dword -> IO Bool32

foreign import ccall unsafe "SetHandleInformation"
  c_SetHandleInformation :: Handle -> Dword -> Dword -> IO Bool32

foreign import ccall unsafe "CreateProcessAsUserW"
  c_CreateProcessAsUserW
    :: Handle -> CWString -> CWString -> Ptr () -> Ptr () -> Bool32
    -> Dword -> Ptr () -> CWString -> Ptr StartupInfoW -> Ptr ProcessInfo -> IO Bool32

foreign import ccall unsafe "CreateProcessWithTokenW"
  c_CreateProcessWithTokenW
    :: Handle -> Dword -> CWString -> CWString
    -> Dword -> Ptr () -> CWString -> Ptr StartupInfoW -> Ptr ProcessInfo -> IO Bool32

foreign import ccall unsafe "CreateProcessW"
  c_CreateProcessW
    :: CWString -> CWString -> Ptr () -> Ptr () -> Bool32
    -> Dword -> Ptr () -> CWString -> Ptr StartupInfoW -> Ptr ProcessInfo -> IO Bool32

foreign import ccall unsafe "ResumeThread"
  c_ResumeThread :: Handle -> IO Dword

foreign import ccall unsafe "WaitForSingleObject"
  c_WaitForSingleObject :: Handle -> Dword -> IO Dword

foreign import ccall unsafe "GetExitCodeProcess"
  c_GetExitCodeProcess :: Handle -> Ptr Dword -> IO Bool32

foreign import ccall unsafe "TerminateProcess"
  c_TerminateProcess :: Handle -> Dword -> IO Bool32

foreign import ccall unsafe "CloseHandle"
  c_CloseHandle :: Handle -> IO Bool32

foreign import ccall unsafe "InitializeProcThreadAttributeList"
  c_InitializeProcThreadAttributeList :: Ptr () -> Dword -> Dword -> Ptr Word64 -> IO Bool32

foreign import ccall unsafe "UpdateProcThreadAttribute"
  c_UpdateProcThreadAttribute
    :: Ptr () -> Dword -> Word64 -> Ptr () -> Word64 -> Ptr () -> Ptr () -> IO Bool32

foreign import ccall unsafe "DeleteProcThreadAttributeList"
  c_DeleteProcThreadAttributeList :: Ptr () -> IO ()

foreign import ccall unsafe "GetLastError"
  c_getLastError :: IO Dword

-- ── 结果类型 ──────────────────────────────────────────────────────────────

data SpawnedProcess = SpawnedProcess
  { spProcess :: Handle   -- ^ 进程句柄
  , spThread  :: Handle   -- ^ 主线程句柄（CREATE_SUSPENDED 时用于 ResumeThread）
  , spPid     :: Dword
  , spStdout  :: Handle   -- ^ stdout 读端（无重定向时为 nullPtr）
  , spStderr  :: Handle   -- ^ stderr 读端
  }

data ProcessError = ProcessError
  { peApi  :: String
  , peCode :: Dword
  }
  deriving (Eq, Show)

mkErr :: String -> IO ProcessError
mkErr api = do
  code <- c_getLastError
  pure (ProcessError api code)

-- ── 路径与命令行 ──────────────────────────────────────────────────────────

-- | 统一把正斜杠转成反斜杠。
--
-- CreateProcessW 对 lpApplicationName 接受正斜杠，但对 lpCurrentDirectory
-- 的接受程度不一致（实测正斜杠会导致 ERROR_FILE_NOT_FOUND）。统一转换。
normalizePath :: FilePath -> FilePath
normalizePath = map toBackslash
  where
    toBackslash c
      | c == '/' = '\\'
      | otherwise = c

renderCommandLine :: FilePath -> [String] -> String
renderCommandLine exe args = unwords (map quoteArg (exe : args))

quoteArg :: String -> String
quoteArg s
  | null s = "\"\""
  | not (any (`elem` (" \t\"" :: String)) s) = s
  | otherwise = '"' : go s ++ "\""
  where
    go [] = []
    go ('"' : rest) = '\\' : '"' : go rest
    go (c : rest) = c : go rest

-- ── spawnRestricted（受限令牌，需要特权）─────────────────────────────────

spawnRestricted
  :: RestrictedToken -> FilePath -> [String] -> FilePath
  -> IO (Either ProcessError SpawnedProcess)
spawnRestricted token exe args cwd =
  withCWString exe $ \wideExe ->
    withCWString (renderCommandLine exe args) $ \wideCmd ->
      withCWString cwd $ \wideCwd ->
        alloca $ \piPtr -> do
          outPair <- createPipe
          case outPair of
            Left e -> pure (Left e)
            Right (outRead, outWrite) -> do
              errPair <- createPipe
              case errPair of
                Left e -> pure (Left e)
                Right (errRead, errWrite) -> do
                  okOut <- c_SetHandleInformation outWrite handleFlagInherit handleFlagInherit
                  okErr <- c_SetHandleInformation errWrite handleFlagInherit handleFlagInherit
                  if okOut == 0 || okErr == 0
                    then pure (Left (ProcessError "SetHandleInformation" 0))
                    else do
                      result <- alloca $ \siPtr -> do
                        poke siPtr StartupInfoW
                          { siFlags = startfUseStdHandles .|. startfUseShowWindow
                          , siShowWindow = swHide
                          , siStdInput = nullPtr
                          , siStdOutput = outWrite
                          , siStdError = errWrite
                          }
                        ok <- c_CreateProcessAsUserW
                          (tokenHandle token)
                          wideExe wideCmd
                          nullPtr nullPtr
                          1
                          (createSuspended .|. createNoWindow)
                          nullPtr wideCwd siPtr piPtr
                        if ok == 0
                          then do
                            -- 降级：普通用户没有 SE_ASSIGNPRIMARYTOKEN_NAME /
                            -- SE_INCREASE_QUOTA_NAME，CreateProcessAsUserW 返回
                            -- ERROR_ACCESS_DENIED(5)。CreateProcessWithTokenW
                            -- 只需 SE_IMPERSONATE_NAME（普通用户通常有）。
                            ok2 <- c_CreateProcessWithTokenW
                              (tokenHandle token) 0
                              wideExe wideCmd
                              (createSuspended .|. createNoWindow)
                              nullPtr wideCwd siPtr piPtr
                            if ok2 == 0
                              then Left <$> mkErr "CreateProcessWithTokenW"
                              else do
                                pi' <- peek piPtr
                                pure (Right (pi', nullPtr, nullPtr))
                          else do
                            pi' <- peek piPtr
                            pure (Right (pi', outRead, errRead))
                      _ <- c_CloseHandle outWrite
                      _ <- c_CloseHandle errWrite
                      case result of
                        Left e -> do
                          _ <- c_CloseHandle outRead
                          _ <- c_CloseHandle errRead
                          pure (Left e)
                        Right (pi', outReadH, errReadH) ->
                          pure (Right SpawnedProcess
                            { spProcess = piProcess pi'
                            , spThread = piThread pi'
                            , spPid = piPid pi'
                            , spStdout = outReadH
                            , spStderr = errReadH
                            })

-- ── spawnPlain（无令牌，无需特权）─────────────────────────────────────────

spawnPlain
  :: FilePath -> [String] -> FilePath
  -> IO (Either ProcessError SpawnedProcess)
spawnPlain exe args cwd =
  withCWString exe $ \wideExe ->
    withCWString (renderCommandLine exe args) $ \wideCmd ->
      withCWString cwd $ \wideCwd ->
        alloca $ \piPtr -> alloca $ \siPtr -> do
          poke siPtr StartupInfoW
            { siFlags = startfUseShowWindow
            , siShowWindow = swHide
            , siStdInput = nullPtr
            , siStdOutput = nullPtr
            , siStdError = nullPtr
            }
          ok <- c_CreateProcessW
            wideExe wideCmd
            nullPtr nullPtr
            0
            (createSuspended .|. createNoWindow)
            nullPtr wideCwd siPtr piPtr
          if ok == 0
            then Left <$> mkErr "CreateProcessW"
            else do
              pi' <- peek piPtr
              pure (Right SpawnedProcess
                { spProcess = piProcess pi'
                , spThread = piThread pi'
                , spPid = piPid pi'
                , spStdout = nullPtr
                , spStderr = nullPtr
                })

-- ── spawnAppContainer（免特权）───────────────────────────────────────────

spawnAppContainer
  :: ContainerSid -> FilePath -> [String] -> FilePath
  -> IO (Either ProcessError SpawnedProcess)
spawnAppContainer container exe args cwd =
  withCWString (normalizePath exe) $ \wideExe ->
    withCWString (renderCommandLine (normalizePath exe) args) $ \wideCmd ->
      withCWString (normalizePath cwd) $ \wideCwd -> do
        outPair <- createPipe
        case outPair of
          Left e -> pure (Left e)
          Right (outRead, outWrite) -> do
            errPair <- createPipe
            case errPair of
              Left e -> do
                _ <- c_CloseHandle outRead
                _ <- c_CloseHandle outWrite
                pure (Left e)
              Right (errRead, errWrite) -> do
                okOut <- c_SetHandleInformation outWrite handleFlagInherit handleFlagInherit
                okErr <- c_SetHandleInformation errWrite handleFlagInherit handleFlagInherit
                if okOut == 0 || okErr == 0
                  then do
                    mapM_ c_CloseHandle [outRead, outWrite, errRead, errWrite]
                    pure (Left (ProcessError "SetHandleInformation" 0))
                  else do
                    result <- alloca $ \secCapsPtr -> alloca $ \piPtr -> alloca $ \sizeOut -> do
                      -- 1. 容器身份（不使用额外 capability）
                      poke secCapsPtr SecurityCapabilities
                        { scAppContainerSid = containerSidRaw container
                        , scCapabilities = nullPtr
                        , scCapabilityCount = 0
                        , scReserved = 0
                        }
                      -- 2. 属性列表需要两次 Initialize：首次 NULL 拿大小（预期失败）
                      _ <- c_InitializeProcThreadAttributeList nullPtr 1 0 sizeOut
                      size <- peek sizeOut
                      if size == 0
                        then pure (Left (ProcessError "InitializeProcThreadAttributeList" 0))
                        else allocaBytes (fromIntegral size) $ \listPtr -> do
                          okInit <- c_InitializeProcThreadAttributeList listPtr 1 0 sizeOut
                          if okInit == 0
                            then Left <$> mkErr "InitializeProcThreadAttributeList"
                            else do
                              okUpd <- c_UpdateProcThreadAttribute
                                listPtr 0 procThreadAttributeSecurityCapabilities
                                (castPtr secCapsPtr) (fromIntegral securityCapabilitiesSize)
                                nullPtr nullPtr
                              if okUpd == 0
                                then do
                                  c_DeleteProcThreadAttributeList listPtr
                                  Left <$> mkErr "UpdateProcThreadAttribute"
                                else do
                                  r <- alloca $ \siExPtr -> do
                                    poke siExPtr StartupInfoExW
                                      { siexFlags = startfUseStdHandles .|. startfUseShowWindow
                                      , siexShowWindow = swHide
                                      , siexStdInput = nullPtr
                                      , siexStdOutput = outWrite
                                      , siexStdError = errWrite
                                      , siexAttributeList = listPtr
                                      }
                                    -- 空环境块（只有两个 UTF-16 NUL）：子进程不继承
                                    -- 父进程环境变量，凭据不会随执行泄露。
                                    allocaArray 2 $ \envPtr -> do
                                      pokeArray envPtr [0, 0 :: Word16]
                                      ok <- c_CreateProcessW
                                        nullPtr
                                        wideCmd
                                        nullPtr nullPtr
                                        1                               -- bInheritHandles
                                        ( extendedStartupInfoPresent
                                            .|. createSuspended
                                            .|. createNoWindow
                                            .|. createUnicodeEnvironment )
                                        (castPtr envPtr) wideCwd
                                        (castPtr siExPtr)
                                        piPtr
                                      if ok == 0
                                        then Left <$> mkErr "CreateProcessW"
                                        else do
                                          pi' <- peek piPtr
                                          pure (Right SpawnedProcess
                                            { spProcess = piProcess pi'
                                            , spThread = piThread pi'
                                            , spPid = piPid pi'
                                            , spStdout = outRead
                                            , spStderr = errRead
                                            })
                                  c_DeleteProcThreadAttributeList listPtr
                                  pure r
                    -- 3. 父进程关掉写端，否则读端永远等不到 EOF
                    _ <- c_CloseHandle outWrite
                    _ <- c_CloseHandle errWrite
                    case result of
                      Left e -> do
                        _ <- c_CloseHandle outRead
                        _ <- c_CloseHandle errRead
                        pure (Left e)
                      Right sp -> pure (Right sp)

-- ── 管道与进程操作 ────────────────────────────────────────────────────────

createPipe :: IO (Either ProcessError (Handle, Handle))
createPipe =
  alloca $ \readOut -> alloca $ \writeOut -> do
    ok <- c_CreatePipe readOut writeOut nullPtr 0
    if ok == 0
      then Left <$> mkErr "CreatePipe"
      else do
        readH <- peek readOut
        writeH <- peek writeOut
        pure (Right (readH, writeH))

resumeThread :: SpawnedProcess -> IO (Either ProcessError ())
resumeThread sp = do
  r <- c_ResumeThread (spThread sp)
  if r == 0xFFFFFFFF
    then Left <$> mkErr "ResumeThread"
    else pure (Right ())

waitForProcess :: SpawnedProcess -> IO (Either ProcessError Dword)
waitForProcess sp = do
  w <- c_WaitForSingleObject (spProcess sp) infinite
  if w /= waitObject0
    then Left <$> mkErr "WaitForSingleObject"
    else alloca $ \codeOut -> do
      ok <- c_GetExitCodeProcess (spProcess sp) codeOut
      if ok == 0
        then Left <$> mkErr "GetExitCodeProcess"
        else Right <$> peek codeOut

terminateProcess :: SpawnedProcess -> IO ()
terminateProcess sp = do
  _ <- c_TerminateProcess (spProcess sp) 1
  pure ()

closeSpawned :: SpawnedProcess -> IO ()
closeSpawned sp = do
  _ <- c_CloseHandle (spProcess sp)
  _ <- c_CloseHandle (spThread sp)
  _ <- c_CloseHandle (spStdout sp)
  _ <- c_CloseHandle (spStderr sp)
  pure ()

-- ── 管道读取 ──────────────────────────────────────────────────────────────

foreign import stdcall unsafe "windows.h ReadFile"
  c_ReadFile :: Handle -> Ptr Word8 -> Dword -> Ptr Dword -> Ptr () -> IO Bool32

-- | 逐块读取管道，直到对端关闭。
--
-- 回调期间 @buf@ 有效且内容不复制——需要保留就立刻拷走。单块上限 4 KiB，
-- 跨块的行切分由调用方负责（这里只负责把字节搬出来）。
--
-- @nRead@ 每次循环前清零：@ReadFile@ 失败时不会写它，不清就会读到上一轮的
-- 垃圾值甚至未初始化内存。
readPipeChunks :: Handle -> (Ptr Word8 -> Int -> IO ()) -> IO ()
readPipeChunks hPipe sink =
  allocaBytes chunkSize $ \buf ->
    alloca $ \nReadPtr -> go buf nReadPtr
  where
    chunkSize = 4096 :: Int
    go buf nReadPtr = do
      poke nReadPtr (0 :: Dword)
      _ <- c_ReadFile hPipe buf (fromIntegral chunkSize) nReadPtr nullPtr
      n <- peek nReadPtr
      if n == 0
        then pure ()
        else do
          sink buf (fromIntegral n)
          go buf nReadPtr
