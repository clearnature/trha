{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.WebGPU.Shader
  ( -- * Shader Management
    createShaderModule
  , createComputePipeline
  , createBindGroupLayout
  , createPipelineLayout
  ) where

import Infrastructure.WebGPU.Types
import Data.Text (Text)
import qualified Data.Text as T

-- | Create a shader module
createShaderModule :: WebGPUDevice -> Text -> IO (Either WebGPUError WebGPUShaderModule)
createShaderModule device code = do
  if T.null code
    then return $ Left $ ShaderCompilationError "Shader code cannot be empty"
    else do
      -- In production, would compile WGSL shader
      let moduleId = 1  -- Would generate unique ID
      return $ Right $ WebGPUShaderModule moduleId code

-- | Create a compute pipeline
createComputePipeline :: WebGPUDevice -> WebGPUShaderModule -> WebGPUPipelineLayout -> IO (Either WebGPUError WebGPUComputePipeline)
createComputePipeline device shaderModule layout = do
  -- In production, would create GPU compute pipeline
  let pipelineId = 1  -- Would generate unique ID
  return $ Right $ WebGPUComputePipeline pipelineId layout

-- | Create a bind group layout
createBindGroupLayout :: WebGPUDevice -> [WebGPUBindGroupLayoutEntry] -> IO (Either WebGPUError WebGPUBindGroupLayout)
createBindGroupLayout device entries = do
  if null entries
    then return $ Left $ PipelineCreationError "Bind group layout must have at least one entry"
    else do
      let layoutId = 1  -- Would generate unique ID
      return $ Right $ WebGPUBindGroupLayout layoutId entries

-- | Create a pipeline layout
createPipelineLayout :: WebGPUDevice -> [WebGPUBindGroupLayout] -> IO (Either WebGPUError WebGPUPipelineLayout)
createPipelineLayout device bindGroupLayouts = do
  if null bindGroupLayouts
    then return $ Left $ PipelineCreationError "Pipeline layout must have at least one bind group layout"
    else do
      let layoutId = 1  -- Would generate unique ID
      return $ Right $ WebGPUPipelineLayout layoutId bindGroupLayouts