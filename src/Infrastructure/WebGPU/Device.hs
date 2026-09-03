{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.WebGPU.Device
  ( -- * Device Management
    createDevice
  , getDeviceLimits
  , deviceLostHandler
  ) where

import Infrastructure.WebGPU.Types
import Data.Text (Text)
import qualified Data.Text as T

-- | Create a WebGPU device
createDevice :: WebGPUConfig -> IO (Either WebGPUError WebGPUDevice)
createDevice config = do
  -- In production, would request device from GPU adapter
  let limits = WebGPULimits
        { maxBufferSize = 268435456  -- 256MB
        , maxStorageBufferBindingSize = 134217728  -- 128MB
        , maxComputeWorkgroupSizeX = 256
        , maxComputeWorkgroupSizeY = 256
        , maxComputeWorkgroupSizeZ = 64
        , maxComputeWorkgroupsPerDimension = 65535
        }
  let deviceName = case configDeviceName config of
        Just name -> name
        Nothing -> "Default Device"
  return $ Right $ WebGPUDevice deviceName limits

-- | Get device limits
getDeviceLimits :: WebGPUDevice -> WebGPULimits
getDeviceLimits = deviceLimits

-- | Device lost handler
deviceLostHandler :: WebGPUDevice -> (Text -> IO ()) -> IO ()
deviceLostHandler device handler = do
  -- In production, would set up device lost callback
  putStrLn $ "Device lost handler registered for: " ++ T.unpack (deviceName device)