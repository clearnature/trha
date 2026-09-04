{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.CPU.Types
  ( -- * CPU Types
    CPUBackend(..)
  , CPUConfig(..)
  , defaultCPUConfig
  
    -- * Architecture
  , CPUArchitecture(..)
  , detectArchitecture
  
    -- * Features
  , CPUFeatures(..)
  , detectFeatures
  
    -- * Errors
  , CPUError(..)
  
    -- * Operations
  , UnaryOp(..)
  , BinaryOp(..)
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import System.Info (arch, os)

-- | CPU backend
data CPUBackend = CPUBackend
  { cpuBackendConfig :: CPUConfig
  , cpuBackendArch :: CPUArchitecture
  , cpuBackendFeatures :: CPUFeatures
  }

-- | CPU configuration
data CPUConfig = CPUConfig
  { configThreads :: Int
  , configBatchSize :: Int
  , configUseSIMD :: Bool
  , configUseBLAS :: Bool
  } deriving (Show, Eq)

-- | Default CPU configuration
defaultCPUConfig :: CPUConfig
defaultCPUConfig = CPUConfig
  { configThreads = 4
  , configBatchSize = 512
  , configUseSIMD = True
  , configUseBLAS = False
  }

-- | CPU architecture
data CPUArchitecture
  = X86_64
  | ARM64
  | ARM32
  | RISCV64
  | LoongArch64
  | PowerPC64
  | S390X
  | Wasm
  | UnknownArch Text
  deriving (Show, Eq)

-- | Detect CPU architecture
detectArchitecture :: CPUArchitecture
detectArchitecture = case arch of
  "x86_64" -> X86_64
  "aarch64" -> ARM64
  "arm" -> ARM32
  "riscv64" -> RISCV64
  "loongarch64" -> LoongArch64
  "powerpc64" -> PowerPC64
  "s390x" -> S390X
  "wasm32" -> Wasm
  "wasm64" -> Wasm
  _ -> UnknownArch (T.pack arch)

-- | CPU features
data CPUFeatures = CPUFeatures
  { featureSSE :: Bool
  , featureSSE2 :: Bool
  , featureSSE3 :: Bool
  , featureSSSE3 :: Bool
  , featureSSE41 :: Bool
  , featureSSE42 :: Bool
  , featureAVX :: Bool
  , featureAVX2 :: Bool
  , featureAVX512 :: Bool
  , featureFMA :: Bool
  , featureF16C :: Bool
  , featureNEON :: Bool
  , featureSVE :: Bool
  , featureSVE2 :: Bool
  } deriving (Show, Eq)

-- | Detect CPU features
detectFeatures :: IO CPUFeatures
detectFeatures = do
  -- Detect features based on architecture
  let arch = detectArchitecture
  case arch of
    X86_64 -> return $ CPUFeatures
      { featureSSE = True
      , featureSSE2 = True
      , featureSSE3 = True
      , featureSSSE3 = True
      , featureSSE41 = True
      , featureSSE42 = True
      , featureAVX = True
      , featureAVX2 = True
      , featureAVX512 = False  -- Would check CPUID in production
      , featureFMA = True
      , featureF16C = True
      , featureNEON = False
      , featureSVE = False
      , featureSVE2 = False
      }
    ARM64 -> return $ CPUFeatures
      { featureSSE = False
      , featureSSE2 = False
      , featureSSE3 = False
      , featureSSSE3 = False
      , featureSSE41 = False
      , featureSSE42 = False
      , featureAVX = False
      , featureAVX2 = False
      , featureAVX512 = False
      , featureFMA = False
      , featureF16C = False
      , featureNEON = True
      , featureSVE = False  -- Would check in production
      , featureSVE2 = False
      }
    _ -> return $ CPUFeatures
      { featureSSE = False
      , featureSSE2 = False
      , featureSSE3 = False
      , featureSSSE3 = False
      , featureSSE41 = False
      , featureSSE42 = False
      , featureAVX = False
      , featureAVX2 = False
      , featureAVX512 = False
      , featureFMA = False
      , featureF16C = False
      , featureNEON = False
      , featureSVE = False
      , featureSVE2 = False
      }

-- | CPU errors
data CPUError
  = ThreadError Text
  | SIMDNotSupported
  | BLASNotAvailable
  | ArchitectureNotSupported CPUArchitecture
  | UnknownCPUError Text
  deriving (Show, Eq)

-- | Unary operation type
data UnaryOp
  = UnaryOpAbs
  | UnaryOpNeg
  | UnaryOpSgn
  | UnaryOpStep
  | UnaryOpTanh
  | UnaryOpElu
  | UnaryOpRelu
  | UnaryOpSigmoid
  | UnaryOpGelu
  | UnaryOpGeluQuick
  | UnaryOpSilu
  | UnaryOpHardswish
  | UnaryOpHardsigmoid
  | UnaryOpExp
  | UnaryOpLog
  | UnaryOpSqrt
  | UnaryOpSin
  | UnaryOpCos
  | UnaryOpCeil
  | UnaryOpFloor
  | UnaryOpRound
  deriving (Show, Eq)

-- | Binary operation type
data BinaryOp
  = BinaryOpAdd
  | BinaryOpSub
  | BinaryOpMul
  | BinaryOpDiv
  | BinaryOpPow
  | BinaryOpMax
  | BinaryOpMin
  | BinaryOpMod
  deriving (Show, Eq)