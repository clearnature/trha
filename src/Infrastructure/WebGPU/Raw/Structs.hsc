{-# LANGUAGE TypeFamilies #-}

-- | WebGPU 描述符结构（@WGPU*Descriptor@）的 Haskell 绑定。
--
-- == 偏移不手算
--
-- 每个 'Storable' 实例的 @sizeOf@ \/ @alignment@ \/ 字段偏移都由 @hsc2hs@ 的
-- @#{size}@ \/ @#{alignment}@ \/ @#{offset}@ **从 C 头文件求值**（C 编译器自己算），
-- 因此升级 @wgpu-native@ 时不会出现"结构布局变了但 Haskell 侧还按旧偏移读写"的
-- 静默错位。头文件：@3rdparty\/wgpu-native\/include\/webgpu\/webgpu.h@（v29.0.1.1）。
--
-- == v29 的命名变化（与旧教程/旧绑定不同，勿照抄网上例子）
--
-- * WGSL 入口叫 'ShaderSourceWGSL'（旧名 @WGPUShaderModuleWGSLDescriptor@ 已不在头文件里），
--   它作为 @nextInChain@ 上的链式结构使用，@sType = WGPUSType_ShaderSourceWGSL@；
-- * compute 阶段描述叫 'ComputeState'（旧名 @WGPUProgrammableStageDescriptor@ 已不存在）；
-- * 字符串统一用 'StringView'（不是 @const char*@）。
--
-- == 可传 NULL 的描述符
--
-- @wgpuCreateInstance@ \/ @wgpuDeviceCreateCommandEncoder@ \/
-- @wgpuCommandEncoderBeginComputePass@ 都接受 @NULL@（用默认值），因此本模块
-- 不提供 @InstanceDescriptor@ 等绑定 —— 少绑一个结构就少一处错位风险。
module Infrastructure.WebGPU.Raw.Structs
  ( -- * 基础
    StringView (..)
  , nullStringView
  , ChainedStruct (..)
  , nullChainedStruct
    -- * Shader 模块
  , ShaderSourceWGSL (..)
  , ShaderModuleDescriptor (..)
    -- * 缓冲
  , BufferDescriptor (..)
    -- * 适配器选择
  , RequestAdapterOptions (..)
    -- * Bind group
  , BufferBindingLayout (..)
  , BindGroupLayoutEntry (..)
  , BindGroupLayoutDescriptor (..)
  , BindGroupEntry (..)
  , BindGroupDescriptor (..)
    -- * 管线
  , PipelineLayoutDescriptor (..)
  , ComputeState (..)
  , ComputePipelineDescriptor (..)
    -- * 常量（同样由 hsc2hs 求值）
  , sTypeShaderSourceWGSL
  , shaderStageCompute
  , bufferBindingTypeUniform
  , bufferBindingTypeStorage
  , bufferBindingTypeReadOnlyStorage
  , bufferBindingTypeNone
  ) where

#include <webgpu/webgpu.h>

import Data.Word (Word32, Word64)
import Foreign.C.Types (CChar, CInt (..))
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (Storable (..))

import Infrastructure.WebGPU.Raw.Enums (BufferUsage, FeatureLevel (..), PowerPreference (..), fromRawFlags, toRawEnum, toRawFlags)

-- ---------------------------------------------------------------------------
-- 基础结构
-- ---------------------------------------------------------------------------

-- | v29 的字符串表示（@WGPUStringView@）：@data@ + @length@ 分开给，
-- 因此**不必**以 NUL 结尾（可表示含 NUL 的切片），但 @data == NULL && length == 0@
-- 表示空字符串。
data StringView = StringView
  { svData :: Ptr CChar
  , svLength :: Word64
  }

instance Show StringView where
  show (StringView p n) = "StringView {svData = " <> show p <> ", svLength = " <> show n <> "}"

instance Eq StringView where
  StringView a b == StringView c d = a == c && b == d

instance Storable StringView where
  sizeOf _ = #{size WGPUStringView}
  alignment _ = #{alignment WGPUStringView}
  peek p =
    StringView
      <$> peekByteOff p #{offset WGPUStringView, data}
      <*> peekByteOff p #{offset WGPUStringView, length}
  poke p x = do
    pokeByteOff p #{offset WGPUStringView, data} (svData x)
    pokeByteOff p #{offset WGPUStringView, length} (svLength x)

-- | 空 @WGPUStringView@（NULL + 0）。
nullStringView :: StringView
nullStringView = StringView nullPtr 0

-- | 链式结构头（@WGPUChainedStruct@）：所有 @nextInChain@ 链上的结构都以它开头。
data ChainedStruct = ChainedStruct
  { csNext :: Ptr ChainedStruct
  , csSType :: CInt
  }

instance Storable ChainedStruct where
  sizeOf _ = #{size WGPUChainedStruct}
  alignment _ = #{alignment WGPUChainedStruct}
  peek p =
    ChainedStruct
      <$> peekByteOff p #{offset WGPUChainedStruct, next}
      <*> peekByteOff p #{offset WGPUChainedStruct, sType}
  poke p x = do
    pokeByteOff p #{offset WGPUChainedStruct, next} (csNext x)
    pokeByteOff p #{offset WGPUChainedStruct, sType} (csSType x)

-- | 终止链的 @nextInChain@ 值（NULL 指针；用 'nullChainedStruct' 的地址即可）。
nullChainedStruct :: ChainedStruct
nullChainedStruct = ChainedStruct nullPtr 0

-- ---------------------------------------------------------------------------
-- Shader 模块
-- ---------------------------------------------------------------------------

-- | WGSL 源（@WGPUShaderSourceWGSL@，v29 名）。作为 @nextInChain@ 的第一节使用。
data ShaderSourceWGSL = ShaderSourceWGSL
  { sswChain :: ChainedStruct
  , sswCode :: StringView
  }

instance Storable ShaderSourceWGSL where
  sizeOf _ = #{size WGPUShaderSourceWGSL}
  alignment _ = #{alignment WGPUShaderSourceWGSL}
  peek p =
    ShaderSourceWGSL
      <$> peekByteOff p #{offset WGPUShaderSourceWGSL, chain}
      <*> peekByteOff p #{offset WGPUShaderSourceWGSL, code}
  poke p x = do
    pokeByteOff p #{offset WGPUShaderSourceWGSL, chain} (sswChain x)
    pokeByteOff p #{offset WGPUShaderSourceWGSL, code} (sswCode x)

-- | @WGPUShaderModuleDescriptor@（只有 @nextInChain@ + @label@；WGSL 经链传入）。
data ShaderModuleDescriptor = ShaderModuleDescriptor
  { smdNextInChain :: Ptr ChainedStruct
  , smdLabel :: StringView
  }

instance Storable ShaderModuleDescriptor where
  sizeOf _ = #{size WGPUShaderModuleDescriptor}
  alignment _ = #{alignment WGPUShaderModuleDescriptor}
  peek p =
    ShaderModuleDescriptor
      <$> peekByteOff p #{offset WGPUShaderModuleDescriptor, nextInChain}
      <*> peekByteOff p #{offset WGPUShaderModuleDescriptor, label}
  poke p x = do
    pokeByteOff p #{offset WGPUShaderModuleDescriptor, nextInChain} (smdNextInChain x)
    pokeByteOff p #{offset WGPUShaderModuleDescriptor, label} (smdLabel x)

-- ---------------------------------------------------------------------------
-- 缓冲
-- ---------------------------------------------------------------------------

-- | @WGPUBufferDescriptor@。
data BufferDescriptor = BufferDescriptor
  { bdNextInChain :: Ptr ChainedStruct
  , bdLabel :: StringView
  , bdUsage :: BufferUsage
  , bdSize :: Word64
  , bdMappedAtCreation :: Word32
  -- ^ @WGPUBool@（C 侧是 @uint32_t@，不是 C99 @bool@）。
  }

instance Storable BufferDescriptor where
  sizeOf _ = #{size WGPUBufferDescriptor}
  alignment _ = #{alignment WGPUBufferDescriptor}
  peek p =
    BufferDescriptor
      <$> peekByteOff p #{offset WGPUBufferDescriptor, nextInChain}
      <*> peekByteOff p #{offset WGPUBufferDescriptor, label}
      <*> (fromRawFlags <$> peekByteOff p #{offset WGPUBufferDescriptor, usage})
      <*> peekByteOff p #{offset WGPUBufferDescriptor, size}
      <*> peekByteOff p #{offset WGPUBufferDescriptor, mappedAtCreation}
  poke p x = do
    pokeByteOff p #{offset WGPUBufferDescriptor, nextInChain} (bdNextInChain x)
    pokeByteOff p #{offset WGPUBufferDescriptor, label} (bdLabel x)
    pokeByteOff p #{offset WGPUBufferDescriptor, usage} (toRawFlags (bdUsage x))
    pokeByteOff p #{offset WGPUBufferDescriptor, size} (bdSize x)
    pokeByteOff p #{offset WGPUBufferDescriptor, mappedAtCreation} (bdMappedAtCreation x)

-- ---------------------------------------------------------------------------
-- 适配器选择
-- ---------------------------------------------------------------------------

-- | @WGPURequestAdapterOptions@。
data RequestAdapterOptions = RequestAdapterOptions
  { raoNextInChain :: Ptr ChainedStruct
  , raoFeatureLevel :: FeatureLevel
  , raoPowerPreference :: PowerPreference
  , raoForceFallbackAdapter :: Word32
  , raoBackendType :: CInt
  , raoCompatibleSurface :: Ptr ()
  }

instance Storable RequestAdapterOptions where
  sizeOf _ = #{size WGPURequestAdapterOptions}
  alignment _ = #{alignment WGPURequestAdapterOptions}
  peek p =
    RequestAdapterOptions
      <$> peekByteOff p #{offset WGPURequestAdapterOptions, nextInChain}
      <*> (featureLevelOf <$> peekByteOff p #{offset WGPURequestAdapterOptions, featureLevel})
      <*> (powerPreferenceOf <$> peekByteOff p #{offset WGPURequestAdapterOptions, powerPreference})
      <*> peekByteOff p #{offset WGPURequestAdapterOptions, forceFallbackAdapter}
      <*> peekByteOff p #{offset WGPURequestAdapterOptions, backendType}
      <*> peekByteOff p #{offset WGPURequestAdapterOptions, compatibleSurface}
  poke p x = do
    pokeByteOff p #{offset WGPURequestAdapterOptions, nextInChain} (raoNextInChain x)
    pokeByteOff p #{offset WGPURequestAdapterOptions, featureLevel} (featureLevelTo (raoFeatureLevel x))
    pokeByteOff p #{offset WGPURequestAdapterOptions, powerPreference} (powerPreferenceTo (raoPowerPreference x))
    pokeByteOff p #{offset WGPURequestAdapterOptions, forceFallbackAdapter} (raoForceFallbackAdapter x)
    pokeByteOff p #{offset WGPURequestAdapterOptions, backendType} (raoBackendType x)
    pokeByteOff p #{offset WGPURequestAdapterOptions, compatibleSurface} (raoCompatibleSurface x)

-- | @WGPUFeatureLevel@ → C 整数。未识别的值按 Undefined。
featureLevelTo :: FeatureLevel -> CInt
featureLevelTo FeatureLevelCompatibility = toRawEnum (#{const WGPUFeatureLevel_Compatibility} :: CInt)
featureLevelTo FeatureLevelCore = toRawEnum (#{const WGPUFeatureLevel_Core} :: CInt)
featureLevelTo FeatureLevelUndefined = toRawEnum (#{const WGPUFeatureLevel_Undefined} :: CInt)

-- | C 整数 → @WGPUFeatureLevel@。
featureLevelOf :: CInt -> FeatureLevel
featureLevelOf w
  | w == (#{const WGPUFeatureLevel_Compatibility} :: CInt) = FeatureLevelCompatibility
  | w == (#{const WGPUFeatureLevel_Core} :: CInt) = FeatureLevelCore
  | otherwise = FeatureLevelUndefined

-- | @WGPUPowerPreference@ → C 整数。
powerPreferenceTo :: PowerPreference -> CInt
powerPreferenceTo PowerPreferenceLowPower = toRawEnum (#{const WGPUPowerPreference_LowPower} :: CInt)
powerPreferenceTo PowerPreferenceHighPerformance = toRawEnum (#{const WGPUPowerPreference_HighPerformance} :: CInt)
powerPreferenceTo PowerPreferenceUndefined = toRawEnum (#{const WGPUPowerPreference_Undefined} :: CInt)

-- | C 整数 → @WGPUPowerPreference@。
powerPreferenceOf :: CInt -> PowerPreference
powerPreferenceOf w
  | w == (#{const WGPUPowerPreference_LowPower} :: CInt) = PowerPreferenceLowPower
  | w == (#{const WGPUPowerPreference_HighPerformance} :: CInt) = PowerPreferenceHighPerformance
  | otherwise = PowerPreferenceUndefined

-- ---------------------------------------------------------------------------
-- Bind group
-- ---------------------------------------------------------------------------

-- | @WGPUBufferBindingLayout@。
data BufferBindingLayout = BufferBindingLayout
  { bblNextInChain :: Ptr ChainedStruct
  , bblType :: CInt
  , bblHasDynamicOffset :: Word32
  , bblMinBindingSize :: Word64
  }

instance Storable BufferBindingLayout where
  sizeOf _ = #{size WGPUBufferBindingLayout}
  alignment _ = #{alignment WGPUBufferBindingLayout}
  peek p =
    BufferBindingLayout
      <$> peekByteOff p #{offset WGPUBufferBindingLayout, nextInChain}
      <*> peekByteOff p #{offset WGPUBufferBindingLayout, type}
      <*> peekByteOff p #{offset WGPUBufferBindingLayout, hasDynamicOffset}
      <*> peekByteOff p #{offset WGPUBufferBindingLayout, minBindingSize}
  poke p x = do
    pokeByteOff p #{offset WGPUBufferBindingLayout, nextInChain} (bblNextInChain x)
    pokeByteOff p #{offset WGPUBufferBindingLayout, type} (bblType x)
    pokeByteOff p #{offset WGPUBufferBindingLayout, hasDynamicOffset} (bblHasDynamicOffset x)
    pokeByteOff p #{offset WGPUBufferBindingLayout, minBindingSize} (bblMinBindingSize x)

-- | @WGPUBindGroupLayoutEntry@。注意后四个 layout 字段在 C 侧是**内嵌结构**，
-- 本绑定按字节布局保留它们（Haskell 侧不逐个建模，避免无谓的类型爆炸）。
data BindGroupLayoutEntry = BindGroupLayoutEntry
  { bgleNextInChain :: Ptr ChainedStruct
  , bgleBinding :: Word32
  , bgleVisibility :: Word64
  , bgleBindingArraySize :: Word32
  , bgleBuffer :: BufferBindingLayout
  }

instance Storable BindGroupLayoutEntry where
  sizeOf _ = #{size WGPUBindGroupLayoutEntry}
  alignment _ = #{alignment WGPUBindGroupLayoutEntry}
  peek p =
    BindGroupLayoutEntry
      <$> peekByteOff p #{offset WGPUBindGroupLayoutEntry, nextInChain}
      <*> peekByteOff p #{offset WGPUBindGroupLayoutEntry, binding}
      <*> peekByteOff p #{offset WGPUBindGroupLayoutEntry, visibility}
      <*> peekByteOff p #{offset WGPUBindGroupLayoutEntry, bindingArraySize}
      <*> peekByteOff p #{offset WGPUBindGroupLayoutEntry, buffer}
  poke p x = do
    pokeByteOff p #{offset WGPUBindGroupLayoutEntry, nextInChain} (bgleNextInChain x)
    pokeByteOff p #{offset WGPUBindGroupLayoutEntry, binding} (bgleBinding x)
    pokeByteOff p #{offset WGPUBindGroupLayoutEntry, visibility} (bgleVisibility x)
    pokeByteOff p #{offset WGPUBindGroupLayoutEntry, bindingArraySize} (bgleBindingArraySize x)
    pokeByteOff p #{offset WGPUBindGroupLayoutEntry, buffer} (bgleBuffer x)

-- | @WGPUBindGroupLayoutDescriptor@。
data BindGroupLayoutDescriptor = BindGroupLayoutDescriptor
  { bgldNextInChain :: Ptr ChainedStruct
  , bgldLabel :: StringView
  , bgldEntryCount :: Word64
  , bgldEntries :: Ptr BindGroupLayoutEntry
  }

instance Storable BindGroupLayoutDescriptor where
  sizeOf _ = #{size WGPUBindGroupLayoutDescriptor}
  alignment _ = #{alignment WGPUBindGroupLayoutDescriptor}
  peek p =
    BindGroupLayoutDescriptor
      <$> peekByteOff p #{offset WGPUBindGroupLayoutDescriptor, nextInChain}
      <*> peekByteOff p #{offset WGPUBindGroupLayoutDescriptor, label}
      <*> peekByteOff p #{offset WGPUBindGroupLayoutDescriptor, entryCount}
      <*> peekByteOff p #{offset WGPUBindGroupLayoutDescriptor, entries}
  poke p x = do
    pokeByteOff p #{offset WGPUBindGroupLayoutDescriptor, nextInChain} (bgldNextInChain x)
    pokeByteOff p #{offset WGPUBindGroupLayoutDescriptor, label} (bgldLabel x)
    pokeByteOff p #{offset WGPUBindGroupLayoutDescriptor, entryCount} (bgldEntryCount x)
    pokeByteOff p #{offset WGPUBindGroupLayoutDescriptor, entries} (bgldEntries x)

-- | @WGPUBindGroupEntry@（v29 把 buffer\/offset\/size 直接内嵌，没有独立的
-- @WGPUBufferBinding@ 结构）。
data BindGroupEntry = BindGroupEntry
  { bgeNextInChain :: Ptr ChainedStruct
  , bgeBinding :: Word32
  , bgeBuffer :: Ptr ()
  , bgeOffset :: Word64
  , bgeSize :: Word64
  , bgeSampler :: Ptr ()
  , bgeTextureView :: Ptr ()
  }

instance Storable BindGroupEntry where
  sizeOf _ = #{size WGPUBindGroupEntry}
  alignment _ = #{alignment WGPUBindGroupEntry}
  peek p =
    BindGroupEntry
      <$> peekByteOff p #{offset WGPUBindGroupEntry, nextInChain}
      <*> peekByteOff p #{offset WGPUBindGroupEntry, binding}
      <*> peekByteOff p #{offset WGPUBindGroupEntry, buffer}
      <*> peekByteOff p #{offset WGPUBindGroupEntry, offset}
      <*> peekByteOff p #{offset WGPUBindGroupEntry, size}
      <*> peekByteOff p #{offset WGPUBindGroupEntry, sampler}
      <*> peekByteOff p #{offset WGPUBindGroupEntry, textureView}
  poke p x = do
    pokeByteOff p #{offset WGPUBindGroupEntry, nextInChain} (bgeNextInChain x)
    pokeByteOff p #{offset WGPUBindGroupEntry, binding} (bgeBinding x)
    pokeByteOff p #{offset WGPUBindGroupEntry, buffer} (bgeBuffer x)
    pokeByteOff p #{offset WGPUBindGroupEntry, offset} (bgeOffset x)
    pokeByteOff p #{offset WGPUBindGroupEntry, size} (bgeSize x)
    pokeByteOff p #{offset WGPUBindGroupEntry, sampler} (bgeSampler x)
    pokeByteOff p #{offset WGPUBindGroupEntry, textureView} (bgeTextureView x)

-- | @WGPUBindGroupDescriptor@。
data BindGroupDescriptor = BindGroupDescriptor
  { bgdNextInChain :: Ptr ChainedStruct
  , bgdLabel :: StringView
  , bgdLayout :: Ptr ()
  , bgdEntryCount :: Word64
  , bgdEntries :: Ptr BindGroupEntry
  }

instance Storable BindGroupDescriptor where
  sizeOf _ = #{size WGPUBindGroupDescriptor}
  alignment _ = #{alignment WGPUBindGroupDescriptor}
  peek p =
    BindGroupDescriptor
      <$> peekByteOff p #{offset WGPUBindGroupDescriptor, nextInChain}
      <*> peekByteOff p #{offset WGPUBindGroupDescriptor, label}
      <*> peekByteOff p #{offset WGPUBindGroupDescriptor, layout}
      <*> peekByteOff p #{offset WGPUBindGroupDescriptor, entryCount}
      <*> peekByteOff p #{offset WGPUBindGroupDescriptor, entries}
  poke p x = do
    pokeByteOff p #{offset WGPUBindGroupDescriptor, nextInChain} (bgdNextInChain x)
    pokeByteOff p #{offset WGPUBindGroupDescriptor, label} (bgdLabel x)
    pokeByteOff p #{offset WGPUBindGroupDescriptor, layout} (bgdLayout x)
    pokeByteOff p #{offset WGPUBindGroupDescriptor, entryCount} (bgdEntryCount x)
    pokeByteOff p #{offset WGPUBindGroupDescriptor, entries} (bgdEntries x)

-- ---------------------------------------------------------------------------
-- 管线
-- ---------------------------------------------------------------------------

-- | @WGPUPipelineLayoutDescriptor@。
data PipelineLayoutDescriptor = PipelineLayoutDescriptor
  { pldNextInChain :: Ptr ChainedStruct
  , pldLabel :: StringView
  , pldBindGroupLayoutCount :: Word64
  , pldBindGroupLayouts :: Ptr ()
  , pldImmediateSize :: Word32
  }

instance Storable PipelineLayoutDescriptor where
  sizeOf _ = #{size WGPUPipelineLayoutDescriptor}
  alignment _ = #{alignment WGPUPipelineLayoutDescriptor}
  peek p =
    PipelineLayoutDescriptor
      <$> peekByteOff p #{offset WGPUPipelineLayoutDescriptor, nextInChain}
      <*> peekByteOff p #{offset WGPUPipelineLayoutDescriptor, label}
      <*> peekByteOff p #{offset WGPUPipelineLayoutDescriptor, bindGroupLayoutCount}
      <*> peekByteOff p #{offset WGPUPipelineLayoutDescriptor, bindGroupLayouts}
      <*> peekByteOff p #{offset WGPUPipelineLayoutDescriptor, immediateSize}
  poke p x = do
    pokeByteOff p #{offset WGPUPipelineLayoutDescriptor, nextInChain} (pldNextInChain x)
    pokeByteOff p #{offset WGPUPipelineLayoutDescriptor, label} (pldLabel x)
    pokeByteOff p #{offset WGPUPipelineLayoutDescriptor, bindGroupLayoutCount} (pldBindGroupLayoutCount x)
    pokeByteOff p #{offset WGPUPipelineLayoutDescriptor, bindGroupLayouts} (pldBindGroupLayouts x)
    pokeByteOff p #{offset WGPUPipelineLayoutDescriptor, immediateSize} (pldImmediateSize x)

-- | @WGPUComputeState@（v29 名；旧名 @WGPUProgrammableStageDescriptor@ 已不在头文件里）。
data ComputeState = ComputeState
  { cstNextInChain :: Ptr ChainedStruct
  , cstModule :: Ptr ()
  , cstEntryPoint :: StringView
  , cstConstantCount :: Word64
  , cstConstants :: Ptr ()
  }

instance Storable ComputeState where
  sizeOf _ = #{size WGPUComputeState}
  alignment _ = #{alignment WGPUComputeState}
  peek p =
    ComputeState
      <$> peekByteOff p #{offset WGPUComputeState, nextInChain}
      <*> peekByteOff p #{offset WGPUComputeState, module}
      <*> peekByteOff p #{offset WGPUComputeState, entryPoint}
      <*> peekByteOff p #{offset WGPUComputeState, constantCount}
      <*> peekByteOff p #{offset WGPUComputeState, constants}
  poke p x = do
    pokeByteOff p #{offset WGPUComputeState, nextInChain} (cstNextInChain x)
    pokeByteOff p #{offset WGPUComputeState, module} (cstModule x)
    pokeByteOff p #{offset WGPUComputeState, entryPoint} (cstEntryPoint x)
    pokeByteOff p #{offset WGPUComputeState, constantCount} (cstConstantCount x)
    pokeByteOff p #{offset WGPUComputeState, constants} (cstConstants x)

-- | @WGPUComputePipelineDescriptor@。
data ComputePipelineDescriptor = ComputePipelineDescriptor
  { cpdNextInChain :: Ptr ChainedStruct
  , cpdLabel :: StringView
  , cpdLayout :: Ptr ()
  , cpdCompute :: ComputeState
  }

instance Storable ComputePipelineDescriptor where
  sizeOf _ = #{size WGPUComputePipelineDescriptor}
  alignment _ = #{alignment WGPUComputePipelineDescriptor}
  peek p =
    ComputePipelineDescriptor
      <$> peekByteOff p #{offset WGPUComputePipelineDescriptor, nextInChain}
      <*> peekByteOff p #{offset WGPUComputePipelineDescriptor, label}
      <*> peekByteOff p #{offset WGPUComputePipelineDescriptor, layout}
      <*> peekByteOff p #{offset WGPUComputePipelineDescriptor, compute}
  poke p x = do
    pokeByteOff p #{offset WGPUComputePipelineDescriptor, nextInChain} (cpdNextInChain x)
    pokeByteOff p #{offset WGPUComputePipelineDescriptor, label} (cpdLabel x)
    pokeByteOff p #{offset WGPUComputePipelineDescriptor, layout} (cpdLayout x)
    pokeByteOff p #{offset WGPUComputePipelineDescriptor, compute} (cpdCompute x)

-- ---------------------------------------------------------------------------
-- 常量（同样由 hsc2hs 求值，不手抄）
-- ---------------------------------------------------------------------------

-- | @WGPUSType_ShaderSourceWGSL@ —— WGSL 链式结构的类型标签。
sTypeShaderSourceWGSL :: CInt
sTypeShaderSourceWGSL = #{const WGPUSType_ShaderSourceWGSL}

-- | @WGPUShaderStage_Compute@（位标志，C 侧是 @uint64_t@）。
shaderStageCompute :: Word64
shaderStageCompute = #{const WGPUShaderStage_Compute}

-- | @WGPUBufferBindingType_Uniform@。
bufferBindingTypeUniform :: CInt
bufferBindingTypeUniform = #{const WGPUBufferBindingType_Uniform}

-- | @WGPUBufferBindingType_Storage@。
bufferBindingTypeStorage :: CInt
bufferBindingTypeStorage = #{const WGPUBufferBindingType_Storage}

-- | @WGPUBufferBindingType_ReadOnlyStorage@。
bufferBindingTypeReadOnlyStorage :: CInt
bufferBindingTypeReadOnlyStorage = #{const WGPUBufferBindingType_ReadOnlyStorage}

-- | @WGPUBufferBindingType_BindingNotUsed@（占位，非 buffer 绑定时用）。
bufferBindingTypeNone :: CInt
bufferBindingTypeNone = #{const WGPUBufferBindingType_BindingNotUsed}
