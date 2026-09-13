{-# LANGUAGE ForeignFunctionInterface #-}

-- | WebGPU 错误：**接管 uncaptured error**，不再让进程被 abort。
--
-- 为什么需要这一层：wgpu-native 遇到任何校验错误时的**默认**行为是
-- @default_uncaptured_error_handler@ —— 直接 panic，实测会让整个进程 abort
-- （开发期这一点很有用：错误直接砸在脸上；但库化后不可接受，一次 usage 写错就杀进程）。
--
-- 做法：创建 device 时经 @trha_wgpu_device_descriptor_init@（C shim）装上自己的
-- @WGPUUncapturedErrorCallback@，回调把 @(type, message)@ 存进 C 侧槽位；
-- Haskell 侧用 'lastError' 查询。与异步那条路一样，**不让 C 回调进 Haskell**
-- （原因见 @cbits\/wgpu_callback_shim.c@：会与 RTS 锁死锁）。
module Infrastructure.WebGPU.Error
  ( GpuError (..)
  , errorTypeName
  , lastError
  , clearError
  ) where

import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..))

-- | 一次 GPU 错误（对应 @WGPUErrorType@ + 消息文本）。
data GpuError = GpuError
  { geType :: Int
  , geMessage :: String
  }
  deriving (Show, Eq)

-- | @WGPUErrorType@ 的原始值 → 名字（0 表示槽位为空）。
errorTypeName :: Int -> String
errorTypeName 0 = "NoError"
errorTypeName 1 = "NoError"
errorTypeName 2 = "Validation"
errorTypeName 3 = "OutOfMemory"
errorTypeName 4 = "Internal"
errorTypeName 5 = "Unknown"
errorTypeName n = "ErrorType#" ++ show n

foreign import ccall unsafe "trha_wgpu_last_error_type"
  cLastErrorType :: IO CInt

foreign import ccall unsafe "trha_wgpu_last_error_message"
  cLastErrorMessage :: IO CString

foreign import ccall unsafe "trha_wgpu_clear_error"
  cClearError :: IO ()

-- | 取最近一次错误；无错误时返回 @Nothing@。
lastError :: IO (Maybe GpuError)
lastError = do
  t <- cLastErrorType
  if t == 0
    then pure Nothing
    else do
      msg <- cLastErrorMessage >>= peekCString
      pure (Just (GpuError (fromIntegral t) msg))

-- | 清空错误槽位（建议每次操作前调用，以便区分新旧错误）。
clearError :: IO ()
clearError = cClearError
