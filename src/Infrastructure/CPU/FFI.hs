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

-- | FFI bindings to CPU operations (placeholder)
-- These would be actual C bindings to optimized CPU implementations

foreign import ccall "cpu_matrix_multiply"
  cpuMatrixMultiply :: Ptr Float -> Ptr Float -> Ptr Float -> CInt -> CInt -> CInt -> IO ()

foreign import ccall "cpu_vector_add"
  cpuVectorAdd :: Ptr Float -> Ptr Float -> Ptr Float -> CInt -> IO ()

foreign import ccall "cpu_softmax"
  cpuSoftmax :: Ptr Float -> Ptr Float -> CInt -> IO ()

foreign import ccall "cpu_rms_norm"
  cpuRMSNorm :: Ptr Float -> Ptr Float -> Ptr Float -> CInt -> IO ()

foreign import ccall "cpu_rope"
  cpuRoPE :: Ptr Float -> Ptr Float -> CInt -> CInt -> IO ()