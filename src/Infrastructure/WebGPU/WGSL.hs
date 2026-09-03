{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.WebGPU.WGSL
  ( -- * WGSL Shaders
    mulMatVecShader
  , mulMatRegTileShader
  , softMaxShader
  , rmsNormMulShader
  , ropeShader
  , unaryShader
  , scaleShader
  , setShader
  , setRowsShader
  , padShader
  , repeatShader
  , rowNormShader
  , sumRowsShader
  , solveTriShader
  , ssmConvShader
  , ssmScanShader
  , upscaleShader
  ) where

import Data.Text (Text)

-- | Matrix-vector multiplication shader
mulMatVecShader :: Text
mulMatVecShader = "// WGSL mul_mat_vec.wgsl placeholder"

-- | Matrix multiplication with register tiling
mulMatRegTileShader :: Text
mulMatRegTileShader = "// WGSL mul_mat_reg_tile.wgsl placeholder"

-- | Softmax shader
softMaxShader :: Text
softMaxShader = "// WGSL soft_max.wgsl placeholder"

-- | RMS normalization with multiplication
rmsNormMulShader :: Text
rmsNormMulShader = "// WGSL rms_norm_mul.wgsl placeholder"

-- | Rotary position embedding
ropeShader :: Text
ropeShader = "// WGSL rope.wgsl placeholder"

-- | Unary operations
unaryShader :: Text
unaryShader = "// WGSL unary.wgsl placeholder"

-- | Scale operation
scaleShader :: Text
scaleShader = "// WGSL scale.wgsl placeholder"

-- | Set operation
setShader :: Text
setShader = "// WGSL set.wgsl placeholder"

-- | Set rows operation
setRowsShader :: Text
setRowsShader = "// WGSL set_rows.wgsl placeholder"

-- | Pad operation
padShader :: Text
padShader = "// WGSL pad.wgsl placeholder"

-- | Repeat operation
repeatShader :: Text
repeatShader = "// WGSL repeat.wgsl placeholder"

-- | Row normalization
rowNormShader :: Text
rowNormShader = "// WGSL row_norm.wgsl placeholder"

-- | Sum rows operation
sumRowsShader :: Text
sumRowsShader = "// WGSL sum_rows.wgsl placeholder"

-- | Solve triangular
solveTriShader :: Text
solveTriShader = "// WGSL solve_tri.wgsl placeholder"

-- | SSM convolution
ssmConvShader :: Text
ssmConvShader = "// WGSL ssm_conv.wgsl placeholder"

-- | SSM scan
ssmScanShader :: Text
ssmScanShader = "// WGSL ssm_scan.wgsl placeholder"

-- | Upscale operation
upscaleShader :: Text
upscaleShader = "// WGSL upscale.wgsl placeholder"