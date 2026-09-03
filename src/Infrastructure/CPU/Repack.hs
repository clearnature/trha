{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.CPU.Repack
  ( -- * Repack Operations
    repackMatrix
  , repackVector
  ) where

import Infrastructure.CPU.Types
import Infrastructure.CPU.Quant
import Data.Text (Text)
import qualified Data.ByteString as BS
import Foreign.Ptr
import Foreign.Storable
import Foreign.Marshal.Alloc (mallocBytes, free)
import Foreign.Marshal.Array (peekArray, pokeArray)

-- | Repack matrix for optimized computation
repackMatrix :: CPUBackend -> QuantType -> Ptr Float -> Int -> Int -> IO BS.ByteString
repackMatrix backend quantType input m n = do
  -- Read matrix data
  let size = m * n
  values <- peekArray size input
  
  -- Quantize based on type
  let quantized = case quantType of
        QuantTypeF32 -> BS.pack $ map (fromIntegral . round . (* 128)) values
        QuantTypeF16 -> BS.pack $ map (fromIntegral . round . (* 256)) values
        QuantTypeQ4_0 -> BS.pack $ map (fromIntegral . round . (* 16)) values
        QuantTypeQ4_1 -> BS.pack $ map (fromIntegral . round . (* 16)) values
        QuantTypeQ5_0 -> BS.pack $ map (fromIntegral . round . (* 32)) values
        QuantTypeQ5_1 -> BS.pack $ map (fromIntegral . round . (* 32)) values
        QuantTypeQ8_0 -> BS.pack $ map (fromIntegral . round) values
        QuantTypeQ8_1 -> BS.pack $ map (fromIntegral . round) values
        _ -> BS.pack $ map (fromIntegral . round) values
  
  return quantized

-- | Repack vector for optimized computation
repackVector :: CPUBackend -> QuantType -> Ptr Float -> Int -> IO BS.ByteString
repackVector backend quantType input size = do
  -- Read vector data
  values <- peekArray size input
  
  -- Quantize based on type
  let quantized = case quantType of
        QuantTypeF32 -> BS.pack $ map (fromIntegral . round . (* 128)) values
        QuantTypeF16 -> BS.pack $ map (fromIntegral . round . (* 256)) values
        QuantTypeQ4_0 -> BS.pack $ map (fromIntegral . round . (* 16)) values
        QuantTypeQ4_1 -> BS.pack $ map (fromIntegral . round . (* 16)) values
        QuantTypeQ5_0 -> BS.pack $ map (fromIntegral . round . (* 32)) values
        QuantTypeQ5_1 -> BS.pack $ map (fromIntegral . round . (* 32)) values
        QuantTypeQ8_0 -> BS.pack $ map (fromIntegral . round) values
        QuantTypeQ8_1 -> BS.pack $ map (fromIntegral . round) values
        _ -> BS.pack $ map (fromIntegral . round) values
  
  return quantized