{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.WebGPU.Test
  ( -- * Tests
    tests
  ) where

import Test.Hspec
import Infrastructure.WebGPU.Types
import Infrastructure.WebGPU.Device
import Infrastructure.WebGPU.Buffer
import Infrastructure.WebGPU.Shader
import Infrastructure.WebGPU.Command
import Infrastructure.WebGPU.Compute
import Infrastructure.WebGPU.Backend
import Infrastructure.WebGPU.Error

-- | WebGPU tests
tests :: Spec
tests = describe "Infrastructure.WebGPU" $ do
  describe "Types" $ do
    it "can create default config" $ do
      let config = defaultWebGPUConfig
      configPowerPreference config `shouldBe` PowerPreferenceHighPerformance
      configForceFallbackAdapter config `shouldBe` False

  describe "Device" $ do
    it "can create device" $ do
      result <- createDevice defaultWebGPUConfig
      case result of
        Right device -> do
          deviceName device `shouldBe` "Default Device"
          maxBufferSize (deviceLimits device) `shouldBe` 268435456
        Left err -> expectationFailure $ "Failed to create device: " ++ show err

  describe "Buffer" $ do
    it "can create buffer" $ do
      deviceResult <- createDevice defaultWebGPUConfig
      case deviceResult of
        Right device -> do
          bufferResult <- createBuffer device 1024 [BufferUsageStorage]
          case bufferResult of
            Right buffer -> do
              bufferSize buffer `shouldBe` 1024
              bufferUsage buffer `shouldBe` [BufferUsageStorage]
            Left err -> expectationFailure $ "Failed to create buffer: " ++ show err
        Left err -> expectationFailure $ "Failed to create device: " ++ show err

  describe "Shader" $ do
    it "can create shader module" $ do
      deviceResult <- createDevice defaultWebGPUConfig
      case deviceResult of
        Right device -> do
          shaderResult <- createShaderModule device "// test shader"
          case shaderResult of
            Right shaderModule -> do
              shaderModuleCode shaderModule `shouldBe` "// test shader"
            Left err -> expectationFailure $ "Failed to create shader: " ++ show err
        Left err -> expectationFailure $ "Failed to create device: " ++ show err

  describe "Backend" $ do
    it "can create backend" $ do
      result <- createWebGPUBackend defaultWebGPUConfig
      case result of
        Right backend -> do
          deviceName (backendDevice backend) `shouldBe` "Default Device"
        Left err -> expectationFailure $ "Failed to create backend: " ++ show err

  describe "Error" $ do
    it "can convert error to text" $ do
      errorToText DeviceNotFoundError `shouldBe` "WebGPU device not found"
      errorToText (DeviceLostError "test") `shouldBe` "WebGPU device lost: test"

    it "can check if error is recoverable" $ do
      isRecoverableError DeviceNotFoundError `shouldBe` False
      isRecoverableError (ShaderCompilationError "test") `shouldBe` True

    it "can get error severity" $ do
      errorSeverity DeviceNotFoundError `shouldBe` SeverityCritical
      errorSeverity (ShaderCompilationError "test") `shouldBe` SeverityError