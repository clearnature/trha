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

-- | Matrix multiplication shader (WGSL)
matrixMultiplyShader :: Text
matrixMultiplyShader = "// WGSL matrix multiplication shader\n\
\@group(0) @binding(0) var<storage, read> a: array<f32>;\n\
\@group(0) @binding(1) var<storage, read> b: array<f32>;\n\
\@group(0) @binding(2) var<storage, read_write> c: array<f32>;\n\
\@group(0) @binding(3) var<uniform> dims: vec4<u32>;\n\
\\n\
\@compute @workgroup_size(16, 16)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let row = id.x;\n\
\    let col = id.y;\n\
\    let m = dims.x;\n\
\    let n = dims.y;\n\
\    let k = dims.z;\n\
\    \n\
\    if (row >= m || col >= k) { return; }\n\
\    \n\
\    var sum = 0.0;\n\
\    for (var i = 0u; i < n; i++) {\n\
\        sum += a[row * n + i] * b[i * k + col];\n\
\    }\n\
\    c[row * k + col] = sum;\n\
\}"

-- | Vector addition shader (WGSL)
vectorAddShader :: Text
vectorAddShader = "// WGSL vector addition shader\n\
\@group(0) @binding(0) var<storage, read> a: array<f32>;\n\
\@group(0) @binding(1) var<storage, read> b: array<f32>;\n\
\@group(0) @binding(2) var<storage, read_write> c: array<f32>;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let i = id.x;\n\
\    c[i] = a[i] + b[i];\n\
\}"

-- | Softmax shader (WGSL)
softmaxShader :: Text
softmaxShader = "// WGSL softmax shader\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(2) var<uniform> size: u32;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    if (id.x >= size) { return; }\n\
\    \n\
\    // Find max for numerical stability\n\
\    var max_val = -1e9;\n\
\    for (var i = 0u; i < size; i++) {\n\
\        max_val = max(max_val, input[i]);\n\
\    }\n\
\    \n\
\    // Compute exp and sum\n\
\    var sum = 0.0;\n\
\    for (var i = 0u; i < size; i++) {\n\
\        output[i] = exp(input[i] - max_val);\n\
\        sum += output[i];\n\
\    }\n\
\    \n\
\    // Normalize\n\
\    output[id.x] /= sum;\n\
\}"

-- | RMS normalization shader (WGSL)
rmsNormShader :: Text
rmsNormShader = "// WGSL RMS normalization shader\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read> weight: array<f32>;\n\
\@group(0) @binding(2) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(3) var<uniform> size: u32;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    if (id.x >= size) { return; }\n\
\    \n\
\    // Compute RMS\n\
\    var sum_sq = 0.0;\n\
\    for (var i = 0u; i < size; i++) {\n\
\        sum_sq += input[i] * input[i];\n\
\    }\n\
\    let rms = sqrt(sum_sq / f32(size) + 1e-6);\n\
\    \n\
\    // Normalize and scale\n\
\    output[id.x] = (input[id.x] / rms) * weight[id.x];\n\
\}"

-- | RoPE shader (WGSL)
ropeShader :: Text
ropeShader = "// WGSL RoPE shader\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(2) var<uniform> params: vec4<u32>;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let i = id.x;\n\
\    let size = params.x;\n\
\    let dim = params.y;\n\
\    \n\
\    if (i >= size) { return; }\n\
\    \n\
\    let pos = f32(i / dim);\n\
\    let freq = pow(10000.0, f32(i % dim) / f32(dim));\n\
\    let angle = pos / freq;\n\
\    \n\
\    output[i] = input[i] * cos(angle);\n\
\}"