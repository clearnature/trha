{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.WebGPU.Device
  ( -- * Device Management
    createDevice
  , getDeviceLimits
  , deviceLostHandler
  ) where

import Infrastructure.WebGPU.Types
import Data.Text (Text)

-- | Create a WebGPU device (placeholder)
createDevice :: WebGPUConfig -> IO (Either WebGPUError WebGPUDevice)
createDevice config = do
  -- Placeholder: in real implementation, request device from adapter
  let limits = WebGPULimits
        { maxBufferSize = 268435456  -- 256MB
        , maxStorageBufferBindingSize = 134217728  -- 128MB
        , maxComputeWorkgroupSizeX = 256
        , maxComputeWorkgroupSizeY = 256
        , maxComputeWorkgroupSizeZ = 64
        , maxComputeWorkgroupsPerDimension = 65535
        }
  return $ Right $ WebGPUDevice "Default Device" limits

-- | Get device limits
getDeviceLimits :: WebGPUDevice -> WebGPULimits
getDeviceLimits = deviceLimits

-- | Device lost handler (placeholder)
deviceLostHandler :: WebGPUDevice -> (Text -> IO ()) -> IO ()
deviceLostDevice handler = do
  -- Placeholder: in real implementation, set up device lost callback
  return ()