{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.CPU.Ops
  ( -- * CPU Operations
    matrixMultiply
  , vectorAdd
  , softmax
  , rmsNorm
  , rope
  , unaryOp
  , binaryOp
  , scaleOp
  , UnaryOp(..)
  , BinaryOp(..)
  ) where

import Infrastructure.CPU.Types
import Infrastructure.CPU.SIMD
import Infrastructure.CPU.BLAS
import Data.Text (Text)
import Foreign.Ptr
import Foreign.Storable
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (peekArray, pokeArray)

-- | Matrix multiplication
matrixMultiply :: CPUBackend -> Ptr Float -> Ptr Float -> Ptr Float -> Int -> Int -> Int -> IO ()
matrixMultiply backend a b c m n k = do
  -- Use SIMD if available, otherwise scalar
  let features = cpuBackendFeatures backend
  if hasSIMDSupport features
    then simdMatrixMultiply a b c m n k
    else do
      -- Scalar fallback
      mapM_ (\i -> do
        mapM_ (\j -> do
          let sum = 0.0
          val <- foldM (\acc l -> do
            valA <- peekElemOff a (i * n + l)
            valB <- peekElemOff b (l * k + j)
            return (acc + valA * valB)
            ) sum [0..n-1]
          pokeElemOff c (i * k + j) val
          ) [0..k-1]
        ) [0..m-1]

-- | Vector addition
vectorAdd :: CPUBackend -> Ptr Float -> Ptr Float -> Ptr Float -> Int -> IO ()
vectorAdd backend a b c size = do
  -- Use SIMD if available
  let features = cpuBackendFeatures backend
  if hasSIMDSupport features
    then simdAdd a b c size
    else do
      -- Scalar fallback
      mapM_ (\i -> do
        valA <- peekElemOff a i
        valB <- peekElemOff b i
        pokeElemOff c i (valA + valB)
        ) [0..size-1]

-- | Softmax
softmax :: CPUBackend -> Ptr Float -> Ptr Float -> Int -> IO ()
softmax backend input output size = do
  -- Find max for numerical stability
  maxVal <- foldM (\acc i -> do
    val <- peekElemOff input i
    return $ max acc val
    ) (-1e9) [0..size-1]
  
  -- Compute exp(x - max) and sum
  (expSum, _) <- foldM (\(acc, i) _ -> do
    val <- peekElemOff input i
    let expVal = exp (val - maxVal)
    pokeElemOff output i expVal
    return (acc + expVal, i + 1)
    ) (0.0, 0) [0..size-1]
  
  -- Normalize
  mapM_ (\i -> do
    val <- peekElemOff output i
    pokeElemOff output i (val / expSum)
    ) [0..size-1]

-- | RMS normalization
rmsNorm :: CPUBackend -> Ptr Float -> Ptr Float -> Ptr Float -> Int -> IO ()
rmsNorm backend input weight output size = do
  -- Compute RMS
  sumSq <- foldM (\acc i -> do
    val <- peekElemOff input i
    return (acc + val * val)
    ) 0.0 [0..size-1]
  
  let rms = sqrt (sumSq / fromIntegral size + 1e-6)
  
  -- Normalize and scale
  mapM_ (\i -> do
    val <- peekElemOff input i
    w <- peekElemOff weight i
    pokeElemOff output i ((val / rms) * w)
    ) [0..size-1]

-- | Rotary position embedding
rope :: CPUBackend -> Ptr Float -> Ptr Float -> Int -> Int -> IO ()
rope backend input output size dim = do
  -- Simplified RoPE implementation
  mapM_ (\i -> do
    val <- peekElemOff input i
    let pos = fromIntegral (i `div` dim)
    let freq = 10000.0 ** (fromIntegral (i `mod` dim) / fromIntegral dim)
    let angle = pos / freq
    let cosVal = cos angle
    let sinVal = sin angle
    -- Apply rotation (simplified)
    pokeElemOff output i (val * cosVal)
    ) [0..size-1]

-- | Unary operation
unaryOp :: CPUBackend -> UnaryOp -> Ptr Float -> Ptr Float -> Int -> IO ()
unaryOp backend op input output size = do
  mapM_ (\i -> do
    val <- peekElemOff input i
    let result = case op of
          UnaryOpAbs -> abs val
          UnaryOpNeg -> negate val
          UnaryOpSgn -> if val > 0 then 1.0 else if val < 0 then -1.0 else 0.0
          UnaryOpStep -> if val > 0 then 1.0 else 0.0
          UnaryOpTanh -> tanh val
          UnaryOpElu -> if val > 0 then val else (exp val - 1)
          UnaryOpRelu -> max 0 val
          UnaryOpSigmoid -> 1 / (1 + exp (negate val))
          UnaryOpGelu -> val * 0.5 * (1 + tanh (sqrt (2 / pi) * (val + 0.044715 * val * val * val)))
          UnaryOpGeluQuick -> val * sigmoid (1.702 * val)
          UnaryOpSilu -> val * sigmoid val
          UnaryOpHardswish -> val * relu6 (val + 3) / 6
          UnaryOpHardsigmoid -> min 1 (max 0 (val * 0.2 + 0.5))
          UnaryOpExp -> exp val
          UnaryOpLog -> log val
          UnaryOpSqrt -> sqrt val
          UnaryOpSin -> sin val
          UnaryOpCos -> cos val
          UnaryOpCeil -> fromIntegral (ceiling val :: Int)
          UnaryOpFloor -> fromIntegral (floor val :: Int)
          UnaryOpRound -> fromIntegral (round val :: Int)
    pokeElemOff output i result
    ) [0..size-1]
  where
    sigmoid x = 1 / (1 + exp (negate x))
    relu6 x = min 6 (max 0 x)

-- | Binary operation
binaryOp :: CPUBackend -> BinaryOp -> Ptr Float -> Ptr Float -> Ptr Float -> Int -> IO ()
binaryOp backend op a b c size = do
  mapM_ (\i -> do
    valA <- peekElemOff a i
    valB <- peekElemOff b i
    let result = case op of
          BinaryOpAdd -> valA + valB
          BinaryOpSub -> valA - valB
          BinaryOpMul -> valA * valB
          BinaryOpDiv -> valA / valB
          BinaryOpPow -> valA ** valB
          BinaryOpMax -> max valA valB
          BinaryOpMin -> min valA valB
          BinaryOpMod -> valA - fromIntegral (floor (valA / valB) :: Int) * valB
    pokeElemOff c i result
    ) [0..size-1]

-- | Scale operation
scaleOp :: CPUBackend -> Ptr Float -> Ptr Float -> Float -> Int -> IO ()
scaleOp backend input output scale size = do
  mapM_ (\i -> do
    val <- peekElemOff input i
    pokeElemOff output i (val * scale)
    ) [0..size-1]

-- Helper function for foldM
foldM :: (Monad m) => (b -> a -> m b) -> b -> [a] -> m b
foldM _ acc [] = return acc
foldM f acc (x:xs) = do
  acc' <- f acc x
  foldM f acc' xs