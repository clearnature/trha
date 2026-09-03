{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.WebGPU.ShaderLib
  ( -- * Shader Library
    matrixMultiplyShader
  , vectorAddShader
  , softmaxShader
  , rmsNormShader
  , ropeShader
  ) where

import Data.Text (Text)

-- | Matrix multiplication shader (placeholder)
matrixMultiplyShader :: Text
matrixMultiplyShader = "// WGSL matrix multiplication shader placeholder"

-- | Vector addition shader (placeholder)
vectorAddShader :: Text
vectorAddShader = "// WGSL vector addition shader placeholder"

-- | Softmax shader (placeholder)
softmaxShader :: Text
softmaxShader = "// WGSL softmax shader placeholder"

-- | RMS normalization shader (placeholder)
rmsNormShader :: Text
rmsNormShader = "// WGSL RMS normalization shader placeholder"

-- | RoPE shader (placeholder)
ropeShader :: Text
ropeShader = "// WGSL RoPE shader placeholder"