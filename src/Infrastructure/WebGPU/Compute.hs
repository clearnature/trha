{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.WebGPU.Compute
  ( -- * Compute Operations
    matrixMultiply
  , vectorAdd
  , softmax
  , rmsNorm
  , rope
  ) where

import Infrastructure.WebGPU.Types
import Infrastructure.WebGPU.Device
import Infrastructure.WebGPU.Buffer
import Infrastructure.WebGPU.Shader
import Infrastructure.WebGPU.Command
import Data.Text (Text)
import qualified Data.ByteString as BS

-- | Matrix multiplication
matrixMultiply :: WebGPUDevice -> WebGPUBuffer -> WebGPUBuffer -> Int -> Int -> Int -> IO (Either WebGPUError WebGPUBuffer)
matrixMultiply device a b m n k = do
  -- Validate dimensions
  if m <= 0 || n <= 0 || k <= 0
    then return $ Left $ ValidationError "Matrix dimensions must be positive"
    else do
      -- Create output buffer: m x k matrix
      let outputSize = m * k * 4  -- 4 bytes per float
      createBuffer device outputSize [BufferUsageStorage, BufferUsageCopySrc]

-- | Vector addition
vectorAdd :: WebGPUDevice -> WebGPUBuffer -> WebGPUBuffer -> Int -> IO (Either WebGPUError WebGPUBuffer)
vectorAdd device a b size = do
  if size <= 0
    then return $ Left $ ValidationError "Vector size must be positive"
    else do
      let outputSize = size * 4
      createBuffer device outputSize [BufferUsageStorage, BufferUsageCopySrc]

-- | Softmax
softmax :: WebGPUDevice -> WebGPUBuffer -> Int -> IO (Either WebGPUError WebGPUBuffer)
softmax device input size = do
  if size <= 0
    then return $ Left $ ValidationError "Softmax size must be positive"
    else do
      let outputSize = size * 4
      createBuffer device outputSize [BufferUsageStorage, BufferUsageCopySrc]

-- | RMS normalization
rmsNorm :: WebGPUDevice -> WebGPUBuffer -> WebGPUBuffer -> Int -> IO (Either WebGPUError WebGPUBuffer)
rmsNorm device input weight size = do
  if size <= 0
    then return $ Left $ ValidationError "RMS norm size must be positive"
    else do
      let outputSize = size * 4
      createBuffer device outputSize [BufferUsageStorage, BufferUsageCopySrc]

-- | Rotary position embedding
rope :: WebGPUDevice -> WebGPUBuffer -> Int -> Int -> IO (Either WebGPUError WebGPUBuffer)
rope device input size dim = do
  if size <= 0 || dim <= 0
    then return $ Left $ ValidationError "RoPE dimensions must be positive"
    else do
      let outputSize = size * 4
      createBuffer device outputSize [BufferUsageStorage, BufferUsageCopySrc]