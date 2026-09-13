{-# LANGUAGE TypeFamilies #-}

-- | WebGPU 的枚举与位标志 —— **值一律经 @hsc2hs@ 从真头文件求值**（@#const@），
-- 不手抄数值。头文件来源：@3rdparty\/wgpu-native\/include\/webgpu\/webgpu.h@
-- （wgpu-native v29.0.1.1）。
--
-- == 为什么用 hsc2hs 而不是手写数值
--
-- wgpu-native 把这些常量定义成 @static const WGPUBufferUsage WGPUBufferUsage_MapRead =
-- 0x…;@（**不是** C 枚举、也不是宏）。手抄数值会在升级库时静默漂移；
-- @hsc2hs@ 的 @#const@ 是"编一个小程序求值"的实现，因此 @static const@ 也能取，
-- 于是**单一事实源就是 C 头文件本身**。
--
-- == 强类型
--
-- 每类标志/枚举各用一个 @newtype@（不导出构造子语义上的原始值混用），
-- 与 'Infrastructure.WebGPU.Raw.Types' 的句柄层一致：类型不同即不可互传。
module Infrastructure.WebGPU.Raw.Enums
  ( -- * 位标志：缓冲用途
    BufferUsage
  , bufferUsageNone
  , bufferUsageMapRead
  , bufferUsageMapWrite
  , bufferUsageCopySrc
  , bufferUsageCopyDst
  , bufferUsageStorage
  , bufferUsageUniform
    -- * 位标志：映射模式
  , MapMode
  , mapModeRead
  , mapModeWrite
    -- * 枚举：适配器/设备选择
  , FeatureLevel(..)
  , PowerPreference(..)
  , BackendType(..)
    -- * 枚举：异步回调
  , CallbackMode(..)
  , MapAsyncStatus(..)
  , QueueWorkDoneStatus(..)
    -- * 原始值互转（仅供 Raw 层）
  , toRawFlags
  , fromRawFlags
  , toRawEnum
  , fromRawEnum
  ) where

#include <webgpu/webgpu.h>

import Data.Bits ((.|.))
import Data.Word (Word64)
import Foreign.C.Types (CInt (..))

-- ---------------------------------------------------------------------------
-- 位标志（WGPUFlags = uint64_t）
-- ---------------------------------------------------------------------------

-- | 缓冲用途位标志（@WGPUBufferUsage@）。
newtype BufferUsage = BufferUsage Word64
  deriving (Eq, Ord, Show)

instance Semigroup BufferUsage where
  BufferUsage a <> BufferUsage b = BufferUsage (a .|. b)

instance Monoid BufferUsage where
  mempty = BufferUsage 0

-- | @WGPUBufferUsage_None@。
bufferUsageNone :: BufferUsage
bufferUsageNone = BufferUsage #{const WGPUBufferUsage_None}

-- | @WGPUBufferUsage_MapRead@ —— 允许 @wgpuBufferMapAsync@ 以读模式映射。
bufferUsageMapRead :: BufferUsage
bufferUsageMapRead = BufferUsage #{const WGPUBufferUsage_MapRead}

-- | @WGPUBufferUsage_MapWrite@。
bufferUsageMapWrite :: BufferUsage
bufferUsageMapWrite = BufferUsage #{const WGPUBufferUsage_MapWrite}

-- | @WGPUBufferUsage_CopySrc@。
bufferUsageCopySrc :: BufferUsage
bufferUsageCopySrc = BufferUsage #{const WGPUBufferUsage_CopySrc}

-- | @WGPUBufferUsage_CopyDst@ —— @wgpuQueueWriteBuffer@ 的前置条件。
bufferUsageCopyDst :: BufferUsage
bufferUsageCopyDst = BufferUsage #{const WGPUBufferUsage_CopyDst}

-- | @WGPUBufferUsage_Storage@。
bufferUsageStorage :: BufferUsage
bufferUsageStorage = BufferUsage #{const WGPUBufferUsage_Storage}

-- | @WGPUBufferUsage_Uniform@。
bufferUsageUniform :: BufferUsage
bufferUsageUniform = BufferUsage #{const WGPUBufferUsage_Uniform}

-- | 映射模式位标志（@WGPUMapMode@）。
newtype MapMode = MapMode Word64
  deriving (Eq, Ord, Show)

instance Semigroup MapMode where
  MapMode a <> MapMode b = MapMode (a .|. b)

instance Monoid MapMode where
  mempty = MapMode 0

-- | @WGPUMapMode_Read@。
mapModeRead :: MapMode
mapModeRead = MapMode #{const WGPUMapMode_Read}

-- | @WGPUMapMode_Write@。
mapModeWrite :: MapMode
mapModeWrite = MapMode #{const WGPUMapMode_Write}

-- ---------------------------------------------------------------------------
-- 枚举
-- ---------------------------------------------------------------------------

-- | 适配器能力级别（@WGPUFeatureLevel@）。
data FeatureLevel
  = FeatureLevelUndefined
  | FeatureLevelCore
  | FeatureLevelCompatibility
  deriving (Eq, Ord, Show)

-- | 电源偏好（@WGPUPowerPreference@）。
data PowerPreference
  = PowerPreferenceUndefined
  | PowerPreferenceLowPower
  | PowerPreferenceHighPerformance
  deriving (Eq, Ord, Show)

-- | 后端类型（@WGPUBackendType@）—— 本机有 Vulkan，选 'BackendTypeVulkan' 可锁定后端。
data BackendType
  = BackendTypeUndefined
  | BackendTypeNull
  | BackendTypeWebGPU
  | BackendTypeD3D11
  | BackendTypeD3D12
  | BackendTypeMetal
  | BackendTypeVulkan
  | BackendTypeOpenGL
  | BackendTypeOpenGLES
  deriving (Eq, Ord, Show)

-- | 回调触发模式（@WGPUCallbackMode@，v29 的新异步模型）。
--
-- * 'CallbackModeWaitAnyOnly' —— 只在 @wgpuInstanceWaitAny@ 里触发；
-- * 'CallbackModeAllowProcessEvents' —— 另在 @wgpuInstanceProcessEvents@ 里触发；
-- * 'CallbackModeAllowSpontaneous' —— 可能在任意线程自发触发（单线程桥接要当心）。
data CallbackMode
  = CallbackModeWaitAnyOnly
  | CallbackModeAllowProcessEvents
  | CallbackModeAllowSpontaneous
  deriving (Eq, Ord, Show)

-- | @wgpuBufferMapAsync@ 的结果状态（@WGPUMapAsyncStatus@）。
data MapAsyncStatus
  = MapAsyncStatusSuccess
  | MapAsyncStatusCallbackCancelled
  | MapAsyncStatusError
  | MapAsyncStatusAborted
  | MapAsyncStatusUnknown
  deriving (Eq, Ord, Show)

-- | 队列工作完成状态（@WGPUQueueWorkDoneStatus@）。
data QueueWorkDoneStatus
  = QueueWorkDoneStatusSuccess
  | QueueWorkDoneStatusCallbackCancelled
  | QueueWorkDoneStatusError
  | QueueWorkDoneStatusUnknown
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- 原始值互转（仅供 Raw/FFI 层；不导出构造子 → 外部只能用上面的常量/模式）
-- ---------------------------------------------------------------------------

-- | 取位标志的原始值。
toRawFlags :: BufferUsage -> Word64
toRawFlags (BufferUsage w) = w

-- | 由原始值构造位标志（FFI 返回值方向）。
fromRawFlags :: Word64 -> BufferUsage
fromRawFlags = BufferUsage

-- | 枚举 → C 整数（WGPU 的 @WGPU*@ 枚举在 C 侧是 @int32@）。
toRawEnum :: (Integral a) => a -> CInt
toRawEnum = fromIntegral

-- | C 整数 → 枚举：给一个"原始值 → 构造子"的查表与兜底构造子。
--
-- >>> fromRawEnum 1 mapAsyncStatusOf MapAsyncStatusUnknown
-- MapAsyncStatusSuccess
fromRawEnum :: CInt -> (CInt -> Maybe a) -> a -> a
fromRawEnum raw lookupCtor fallback = maybe fallback id (lookupCtor raw)
