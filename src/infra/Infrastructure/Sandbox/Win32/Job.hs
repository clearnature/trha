{-# LANGUAGE ForeignFunctionInterface #-}

-- | Job Object（T4.4）：进程生命周期约束。
--
-- 关键限制位 @JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE@：最后一个 Job 句柄关闭时
-- 杀掉全部成员进程。这是「宿主崩溃后不留下孤儿」的可靠机制——仅靠
-- @CREATE_SUSPENDED@ 或父子关系都不够（Windows 没有 Linux 的 @PR_SET_PDEATHSIG@）。
module Infrastructure.Sandbox.Win32.Job
  ( Job
  , jobHandle
  , JobLimits(..)
  , defaultJobLimits
  , JobError(..)
  , createJob
  , assignToJob
  , closeJob
  ) where

import Data.Bits ((.|.))
import Data.Word (Word32, Word64)
import Foreign
import Foreign.C.Types (CInt(..))

type Handle = Ptr ()
type Dword  = Word32
type Bool32 = CInt

-- ── 常量 ──────────────────────────────────────────────────────────────────

-- | @JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE@
jobObjectLimitKillOnJobClose :: Dword
jobObjectLimitKillOnJobClose = 0x00002000

-- | @JOB_OBJECT_LIMIT_PROCESS_MEMORY@
jobObjectLimitProcessMemory :: Dword
jobObjectLimitProcessMemory = 0x00000100

-- | @JOB_OBJECT_LIMIT_ACTIVE_PROCESS@
jobObjectLimitActiveProcess :: Dword
jobObjectLimitActiveProcess = 0x00000008

-- | @JobObjectExtendedLimitInformation@（JOBOBJECTINFOCLASS）
jobObjectExtendedLimitInformation :: Dword
jobObjectExtendedLimitInformation = 9

-- | @JOBOBJECT_EXTENDED_LIMIT_INFORMATION@ 的大小（x64：144 字节）。
--
-- 布局：@BasicLimitInformation@\@0（64，其中 LimitFlags\@16、ActiveProcessLimit\@40）、
-- @IoInfo@\@64（48）、@ProcessMemoryLimit@\@112（8）、@JobMemoryLimit@\@120、
-- @PeakProcessMemoryUsed@\@128、@PeakJobMemoryUsed@\@136。
jobObjectExtendedLimitSize :: Int
jobObjectExtendedLimitSize = 144

offsetLimitFlags :: Int
offsetLimitFlags = 16

offsetActiveProcessLimit :: Int
offsetActiveProcessLimit = 40

offsetProcessMemoryLimit :: Int
offsetProcessMemoryLimit = 112

-- ── 外部函数 ──────────────────────────────────────────────────────────────

foreign import ccall unsafe "CreateJobObjectW"
  c_CreateJobObjectW :: Ptr () -> Ptr () -> IO Handle

foreign import ccall unsafe "SetInformationJobObject"
  c_SetInformationJobObject :: Handle -> Dword -> Ptr () -> Dword -> IO Bool32

foreign import ccall unsafe "AssignProcessToJobObject"
  c_AssignProcessToJobObject :: Handle -> Handle -> IO Bool32

foreign import ccall unsafe "CloseHandle"
  c_CloseHandle :: Handle -> IO Bool32

foreign import ccall unsafe "GetLastError"
  c_getLastError :: IO Dword

-- ── 类型 ──────────────────────────────────────────────────────────────────

-- | Job Object 句柄的 RAII 包装。
newtype Job = Job Handle

-- | 原始句柄。
jobHandle :: Job -> Handle
jobHandle (Job h) = h

-- | Job 的限制配置。@Nothing@ 表示不设该项。
data JobLimits = JobLimits
  { jlMemoryBytes     :: Maybe Word64   -- ^ 每个进程的提交内存上限（字节）
  , jlActiveProcesses :: Maybe Dword    -- ^ 同时在 Job 中的进程数上限
  }

-- | 只带 @KILL_ON_JOB_CLOSE@，不设内存/进程数上限。
defaultJobLimits :: JobLimits
defaultJobLimits = JobLimits Nothing Nothing

data JobError = JobError
  { jeApi  :: String
  , jeCode :: Dword
  }
  deriving (Eq, Show)

mkErr :: String -> IO JobError
mkErr api = do
  code <- c_getLastError
  pure (JobError api code)

-- ── 主流程 ────────────────────────────────────────────────────────────────

-- | 创建 Job 并应用限制。**总是**带 @KILL_ON_JOB_CLOSE@。
createJob :: JobLimits -> IO (Either JobError Job)
createJob limits = do
  handle <- c_CreateJobObjectW nullPtr nullPtr
  if handle == nullPtr
    then Left <$> mkErr "CreateJobObjectW"
    else allocaBytes jobObjectExtendedLimitSize $ \info -> do
      fillBytes info 0 jobObjectExtendedLimitSize
      pokeByteOff info offsetLimitFlags (limitFlags limits)
      case jlActiveProcesses limits of
        Just n  -> pokeByteOff info offsetActiveProcessLimit n
        Nothing -> pure ()
      case jlMemoryBytes limits of
        Just n  -> pokeByteOff info offsetProcessMemoryLimit n
        Nothing -> pure ()
      ok <- c_SetInformationJobObject
        handle
        jobObjectExtendedLimitInformation
        (castPtr info)
        (fromIntegral jobObjectExtendedLimitSize)
      if ok == 0
        then do
          _ <- c_CloseHandle handle
          Left <$> mkErr "SetInformationJobObject"
        else pure (Right (Job handle))

limitFlags :: JobLimits -> Dword
limitFlags limits =
  jobObjectLimitKillOnJobClose
    .|. (case jlMemoryBytes limits of Just _ -> jobObjectLimitProcessMemory; Nothing -> 0)
    .|. (case jlActiveProcesses limits of Just _ -> jobObjectLimitActiveProcess; Nothing -> 0)

-- | 把已启动的进程加入 Job。
--
-- 调用方应让进程处于挂起态（@CREATE_SUSPENDED@）时加入，再恢复执行——
-- 否则子进程可能在加入前就跑完或派生出孙进程，跳出约束。
assignToJob :: Job -> Handle -> IO (Either JobError ())
assignToJob job process = do
  ok <- c_AssignProcessToJobObject (jobHandle job) process
  if ok == 0
    then Left <$> mkErr "AssignProcessToJobObject"
    else pure (Right ())

-- | 关闭 Job 句柄。若是最后一个句柄，@KILL_ON_JOB_CLOSE@ 会终止全部成员。
closeJob :: Job -> IO ()
closeJob (Job h) = () <$ c_CloseHandle h
