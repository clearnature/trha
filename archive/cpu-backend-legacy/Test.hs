{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.CPU.Test
  ( -- * Tests
    tests
  ) where

import Test.Hspec
import Infrastructure.CPU.Types
import Infrastructure.CPU.Backend
import Infrastructure.CPU.Thread
import Infrastructure.CPU.SIMD
import Infrastructure.CPU.BLAS
import Infrastructure.CPU.Quant
import Infrastructure.CPU.Ops
import Infrastructure.CPU.Error

-- | CPU tests
tests :: Spec
tests = describe "Infrastructure.CPU" $ do
  describe "Types" $ do
    it "can create default config" $ do
      let config = defaultCPUConfig
      configThreads config `shouldBe` 4
      configBatchSize config `shouldBe` 512
      configUseSIMD config `shouldBe` True
      configUseBLAS config `shouldBe` False

    it "can detect architecture" $ do
      let arch = detectArchitecture
      arch `shouldBe` X86_64  -- Assuming x86_64 for testing

  describe "Backend" $ do
    it "can create backend" $ do
      result <- createCPUBackend defaultCPUConfig
      case result of
        Right backend -> do
          cpuBackendArch backend `shouldBe` X86_64
          configThreads (cpuBackendConfig backend) `shouldBe` 4
        Left err -> expectationFailure $ "Failed to create backend: " ++ show err

  describe "Thread" $ do
    it "can create thread pool" $ do
      poolResult <- createThreadPool 4
      case poolResult of
        Right pool -> do
          length (poolThreads pool) `shouldBe` 4
          destroyThreadPool pool
        Left err -> expectationFailure $ "Failed to create thread pool: " ++ show err

  describe "SIMD" $ do
    it "can detect SIMD type" $ do
      features <- detectFeatures
      let simdType = detectSIMDType features
      simdType `shouldBe` AVX2  -- Assuming AVX2 for testing

    it "can check SIMD support" $ do
      features <- detectFeatures
      hasSIMDSupport features `shouldBe` True

  describe "Quant" $ do
    it "can detect quant format" $ do
      let format = detectQuantFormat QuantTypeQ4_0
      quantFormatType format `shouldBe` QuantTypeQ4_0
      quantFormatBlockSize format `shouldBe` 32
      quantFormatBitsPerWeight format `shouldBe` 4.5

  describe "Error" $ do
    it "can convert error to text" $ do
      errorToText (ThreadError "test") `shouldBe` "Thread error: test"
      errorToText SIMDNotSupported `shouldBe` "SIMD not supported"

    it "can check if error is recoverable" $ do
      isRecoverableError (ThreadError "test") `shouldBe` True
      isRecoverableError SIMDNotSupported `shouldBe` True
      isRecoverableError (ArchitectureNotSupported X86_64) `shouldBe` False

    it "can get error severity" $ do
      errorSeverity (ThreadError "test") `shouldBe` SeverityError
      errorSeverity SIMDNotSupported `shouldBe` SeverityWarning
      errorSeverity (ArchitectureNotSupported X86_64) `shouldBe` SeverityCritical