{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.WebGPU.Types
  ( -- * WebGPU Types
    WebGPUDevice(..)
  , WebGPUBuffer(..)
  , WebGPUShaderModule(..)
  , WebGPUComputePipeline(..)
  , WebGPUCommandEncoder(..)
  , WebGPUComputePassEncoder(..)
  
    -- * Configuration
  , WebGPUConfig(..)
  , defaultWebGPUConfig
  
    -- * Errors
  , WebGPUError(..)
  ) where

import Data.Text (Text)

-- | WebGPU device
data WebGPUDevice = WebGPUDevice
  { deviceName :: Text
  , deviceLimits :: WebGPULimits
  }

-- | WebGPU limits
data WebGPULimits = WebGPULimits
  { maxBufferSize :: Int
  , maxStorageBufferBindingSize :: Int
  , maxComputeWorkgroupSizeX :: Int
  , maxComputeWorkgroupSizeY :: Int
  , maxComputeWorkgroupSizeZ :: Int
  , maxComputeWorkgroupsPerDimension :: Int
  } deriving (Show, Eq)

-- | WebGPU buffer
data WebGPUBuffer = WebGPUBuffer
  { bufferId :: Int
  , bufferSize :: Int
  , bufferUsage :: [WebGPUBufferUsage]
  }

-- | WebGPU buffer usage
data WebGPUBufferUsage
  = BufferUsageMapRead
  | BufferUsageMapWrite
  | BufferUsageCopySrc
  | BufferUsageCopyDst
  | BufferUsageStorage
  | BufferUsageUniform
  deriving (Show, Eq)

-- | WebGPU shader module
data WebGPUShaderModule = WebGPUShaderModule
  { shaderModuleId :: Int
  , shaderModuleCode :: Text
  }

-- | WebGPU compute pipeline
data WebGPUComputePipeline = WebGPUComputePipeline
  { pipelineId :: Int
  , pipelineLayout :: WebGPUPipelineLayout
  }

-- | WebGPU pipeline layout
data WebGPUPipelineLayout = WebGPUPipelineLayout
  { layoutId :: Int
  , bindGroupLayouts :: [WebGPUBindGroupLayout]
  }

-- | WebGPU bind group layout
data WebGPUBindGroupLayout = WebGPUBindGroupLayout
  { bindGroupLayoutId :: Int
  , entries :: [WebGPUBindGroupLayoutEntry]
  }

-- | WebGPU bind group layout entry
data WebGPUBindGroupLayoutEntry = WebGPUBindGroupLayoutEntry
  { binding :: Int
  , visibility :: [WebGPUShaderStage]
  , buffer :: Maybe WebGPUBufferBindingLayout
  }

-- | WebGPU shader stage
data WebGPUShaderStage
  = ShaderStageVertex
  | ShaderStageFragment
  | ShaderStageCompute
  deriving (Show, Eq)

-- | WebGPU buffer binding layout
data WebGPUBufferBindingLayout = WebGPUBufferBindingLayout
  { bufferBindingType :: WebGPUBufferBindingType
  , hasDynamicOffset :: Bool
  , minBindingSize :: Int
  }

-- | WebGPU buffer binding type
data WebGPUBufferBindingType
  = BufferBindingTypeUniform
  | BufferBindingTypeStorage
  | BufferBindingTypeReadOnlyStorage
  deriving (Show, Eq)

-- | WebGPU command encoder
data WebGPUCommandEncoder = WebGPUCommandEncoder
  { encoderId :: Int
  }

-- | WebGPU compute pass encoder
data WebGPUComputePassEncoder = WebGPUComputePassEncoder
  { passEncoderId :: Int
  }

-- | WebGPU configuration
data WebGPUConfig = WebGPUConfig
  { configDeviceName :: Maybe Text
  , configPowerPreference :: WebGPUPowerPreference
  , configForceFallbackAdapter :: Bool
  } deriving (Show, Eq)

-- | WebGPU power preference
data WebGPUPowerPreference
  = PowerPreferenceLowPower
  | PowerPreferenceHighPerformance
  deriving (Show, Eq)

-- | Default WebGPU configuration
defaultWebGPUConfig :: WebGPUConfig
defaultWebGPUConfig = WebGPUConfig
  { configDeviceName = Nothing
  , configPowerPreference = PowerPreferenceHighPerformance
  , configForceFallbackAdapter = False
  }

-- | WebGPU errors
data WebGPUError
  = DeviceNotFoundError
  | DeviceLostError Text
  | ShaderCompilationError Text
  | PipelineCreationError Text
  | BufferCreationError Text
  | CommandEncoderError Text
  | UnknownWebGPUError Text
  deriving (Show, Eq)