{-# LANGUAGE OverloadedStrings #-}

-- | Block dequantisation for ggml/GGUF tensor types.
--
-- Every layout and formula here was transcribed from llama.cpp's
-- @ggml/src/ggml-common.h@ (struct sizes) and @ggml/src/ggml-quants.c@
-- (formulas), with the reference line noted per case — not from memory.
--
-- The one detail that is easy to get wrong: for the 4-bit types the low
-- nibble of @qs[j]@ lands at index @j@ and the high nibble at index
-- @j + qk\/2@ — the two halves are *not* interleaved.
module Infrastructure.CPU.Dequant
  ( fp16ToFloat
  , typeBlockGeometry
  , dequantizeRow
  ) where

import Data.Bits ((.&.), (.|.), shiftL, shiftR, testBit)
import Data.Int (Int8)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16, Word32)
import GHC.Float (castWord32ToFloat)
import Infrastructure.CPU.Quant (QuantType(..))

-- | IEEE 754 binary16 → Float (what @GGML_FP16_TO_FP32@ does).
fp16ToFloat :: Word16 -> Float
fp16ToFloat h
  | expo == 0  = sign * (fromIntegral mant / 1024) * (2 ** (-14))   -- subnormal
  | expo == 31 = if mant == 0 then sign * (1 / 0) else 0 / 0        -- inf / NaN
  | otherwise  = sign * (1 + fromIntegral mant / 1024) * (2 ** (fromIntegral expo - 15))
  where
    sign = if testBit h 15 then -1 else 1 :: Float
    expo = fromIntegral ((h `shiftR` 10) .&. 0x1F) :: Int
    mant = fromIntegral (h .&. 0x3FF) :: Int

-- | @(elements per block, bytes per block)@ — struct sizes from ggml-common.h
-- (Q4_0 18B, Q4_1 20B, Q5_0 22B, Q5_1 24B, Q8_0 34B, Q8_1 36B over 32 weights;
-- F32/F16 are one element per "block").
typeBlockGeometry :: QuantType -> Maybe (Int, Int)
typeBlockGeometry t = case t of
  QuantTypeF32  -> Just (1, 4)
  QuantTypeF16  -> Just (1, 2)
  QuantTypeQ4_0 -> Just (32, 18)
  QuantTypeQ4_1 -> Just (32, 20)
  QuantTypeQ5_0 -> Just (32, 22)
  QuantTypeQ5_1 -> Just (32, 24)
  QuantTypeQ8_0 -> Just (32, 34)
  QuantTypeQ8_1 -> Just (32, 36)
  _             -> Nothing   -- K-quants / IQ4_NL arrive in a later milestone

-- | Dequantise @n@ elements of quantised data (little-endian on the wire).
dequantizeRow :: QuantType -> BS.ByteString -> Int -> Either Text [Float]
dequantizeRow ty bs nElems =
  case typeBlockGeometry ty of
    Nothing -> Left ("Dequant: unsupported type " <> T.pack (show ty))
    Just (qk, tsz)
      | nElems `mod` qk /= 0 ->
          Left ("Dequant: " <> T.pack (show nElems) <> " is not a multiple of "
                <> T.pack (show qk))
      | BS.length bs < nb * tsz ->
          Left ("Dequant: need " <> T.pack (show (nb * tsz)) <> " bytes, got "
                <> T.pack (show (BS.length bs)))
      | otherwise -> Right (concatMap (block qk tsz) [0 .. nb - 1])
      where
        nb = nElems `div` qk
  where
    u8At off          = fromIntegral (BS.index bs off) :: Int
    i8At off          = fromIntegral (fromIntegral (BS.index bs off) :: Int8)
    le16At off        = fromIntegral (u8At off) + 256 * fromIntegral (u8At (off + 1)) :: Word16
    le32At off        = fromIntegral (le16At off) + 65536 * fromIntegral (le16At (off + 2)) :: Word32
    f16At off         = fp16ToFloat (le16At off)
    f32At off         = castWord32ToFloat (le32At off)
    -- the four bytes of a Q5 "qh" word, little-endian
    qhBit qh j        = (qh `shiftR` j) .&. 1

    block qk tsz i =
      let off = i * tsz
          qs  = off + 2                      -- past the fp16 scale for 4/5-bit types
          half = qk `div` 2
      in case ty of
        -- y[j] = qs[j] * d
        QuantTypeF32  -> [ f32At (off + 4 * j) | j <- [0 .. qk - 1] ]
        QuantTypeF16  -> [ f16At (off + 2 * j) | j <- [0 .. qk - 1] ]
        QuantTypeQ8_0 -> let d = f16At off
                         in [ fromIntegral (i8At (qs + j)) * d | j <- [0 .. qk - 1] ]
        -- Q8_1 is the same shape with an extra sum field; y = qs * d
        QuantTypeQ8_1 -> let d = f16At off
                         in [ fromIntegral (i8At (qs + 2 + j)) * d | j <- [0 .. qk - 1] ]
        -- y[j] = ((qs[j] & 0x0F) - 8) * d ,  y[j + 16] = ((qs[j] >> 4) - 8) * d
        QuantTypeQ4_0 -> let d = f16At off
                         in [ fromIntegral ((u8At (qs + j) .&. 0x0F) - 8) * d | j <- [0 .. half - 1] ]
                            ++ [ fromIntegral ((u8At (qs + j) `shiftR` 4) - 8) * d | j <- [0 .. half - 1] ]
        -- y = nibble * d + m   (no offset on the nibble)
        QuantTypeQ4_1 -> let d = f16At off
                             m = f16At (off + 2)
                         in [ fromIntegral (u8At (qs + 2 + j) .&. 0x0F) * d + m | j <- [0 .. half - 1] ]
                            ++ [ fromIntegral (u8At (qs + 2 + j) `shiftR` 4) * d + m | j <- [0 .. half - 1] ]
        -- 5-bit: the 5th bit lives in qh, bit j for the low half and bit j+12
        -- for the high half (ggml-quants.c:514-518); value is biased by 16.
        QuantTypeQ5_0 -> let d  = f16At off
                             qh = fromIntegral (le32At (off + 2)) :: Int
                             nib k s = u8At (off + 6 + k) `shiftR` s .&. 0x0F
                         in [ fromIntegral ((nib j 0 .|. (qhBit qh j `shiftL` 4)) - 16) * d
                            | j <- [0 .. half - 1] ]
                            ++ [ fromIntegral ((nib j 4 .|. (qhBit qh (j + 12) `shiftL` 4)) - 16) * d
                               | j <- [0 .. half - 1] ]
        -- 5-bit with min: y = value * d + m, no bias
        QuantTypeQ5_1 -> let d  = f16At off
                             m  = f16At (off + 2)
                             qh = fromIntegral (le32At (off + 4)) :: Int
                             nib k s = u8At (off + 8 + k) `shiftR` s .&. 0x0F
                         in [ fromIntegral (nib j 0 .|. (qhBit qh j `shiftL` 4)) * d + m
                            | j <- [0 .. half - 1] ]
                            ++ [ fromIntegral (nib j 4 .|. (qhBit qh (j + 12) `shiftL` 4)) * d + m
                               | j <- [0 .. half - 1] ]
        _ -> []
