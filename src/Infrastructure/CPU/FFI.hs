{-# LANGUAGE ForeignFunctionInterface #-}

module Infrastructure.CPU.FFI
  ( -- * FFI Bindings
    cpuMatrixMultiply
  , cpuVectorAdd
  , cpuSoftmax
  , cpuRMSNorm
  , cpuRoPE
  ) where

import Foreign.C.Types
import Foreign.Ptr
import Foreign.Storable
import Data.Text (Text)
import qualified Data.Text.Foreign as TF

-- | FFI bindings to CPU operations
-- These are actual C bindings to optimized CPU implementations
-- In production, these would link to optimized C libraries

-- | Matrix multiplication
foreign import ccall "cpu_matrix_multiply"
  cpuMatrixMultiply :: Ptr Float -> Ptr Float -> Ptr Float -> CInt -> CInt -> CInt -> IO ()

-- | Vector addition
foreign import ccall "cpu_vector_add"
  cpuVectorAdd :: Ptr Float -> Ptr Float -> Ptr Float -> CInt -> IO ()

-- | Softmax
foreign import ccall "cpu_softmax"
  cpuSoftmax :: Ptr Float -> Ptr Float -> CInt -> IO ()

-- | RMS normalization
foreign import ccall "cpu_rms_norm"
  cpuRMSNorm :: Ptr Float -> Ptr Float -> Ptr Float -> CInt -> IO ()

-- | RoPE
foreign import ccall "cpu_rope"
  cpuRoPE :: Ptr Float -> Ptr Float -> CInt -> CInt -> IO ()