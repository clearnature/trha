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
mulMatVecShader = "// WGSL mul_mat_vec.wgsl\n\
\@group(0) @binding(0) var<storage, read> matrix: array<f32>;\n\
\@group(0) @binding(1) var<storage, read> vector: array<f32>;\n\
\@group(0) @binding(2) var<storage, read_write> result: array<f32>;\n\
\@group(0) @binding(3) var<uniform> dims: vec2<u32>;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let row = id.x;\n\
\    let cols = dims.y;\n\
\    \n\
\    if (row >= dims.x) { return; }\n\
\    \n\
\    var sum = 0.0;\n\
\    for (var col = 0u; col < cols; col++) {\n\
\        sum += matrix[row * cols + col] * vector[col];\n\
\    }\n\
\    result[row] = sum;\n\
\}"

-- | Matrix multiplication with register tiling
mulMatRegTileShader :: Text
mulMatRegTileShader = "// WGSL mul_mat_reg_tile.wgsl\n\
\const TILE_SIZE: u32 = 16u;\n\
\\n\
\@group(0) @binding(0) var<storage, read> a: array<f32>;\n\
\@group(0) @binding(1) var<storage, read> b: array<f32>;\n\
\@group(0) @binding(2) var<storage, read_write> c: array<f32>;\n\
\@group(0) @binding(3) var<uniform> dims: vec4<u32>;\n\
\\n\
\var<workgroup> tileA: array<f32, 256>;\n\
\var<workgroup> tileB: array<f32, 256>;\n\
\\n\
\@compute @workgroup_size(16, 16)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>, @builtin(workgroup_id) gid: vec3<u32>) {\n\
\    let row = id.x;\n\
\    let col = id.y;\n\
\    let m = dims.x;\n\
\    let n = dims.y;\n\
\    let k = dims.z;\n\
\    \n\
\    if (row >= m || col >= k) { return; }\n\
\    \n\
\    var sum = 0.0;\n\
\    \n\
\    for (var t = 0u; t < n; t += TILE_SIZE) {\n\
\        // Load tiles\n\
\        let aIdx = row * n + t + col % TILE_SIZE;\n\
\        let bIdx = (t + row % TILE_SIZE) * k + col;\n\
\        \n\
\        tileA[col % TILE_SIZE * TILE_SIZE + row % TILE_SIZE] = a[aIdx];\n\
\        tileB[row % TILE_SIZE * TILE_SIZE + col % TILE_SIZE] = b[bIdx];\n\
\        \n\
\        workgroupBarrier();\n\
\        \n\
\        // Compute partial sum\n\
\        for (var i = 0u; i < TILE_SIZE && t + i < n; i++) {\n\
\            sum += tileA[col % TILE_SIZE * TILE_SIZE + i] * tileB[i * TILE_SIZE + row % TILE_SIZE];\n\
\        }\n\
\        \n\
\        workgroupBarrier();\n\
\    }\n\
\    \n\
\    c[row * k + col] = sum;\n\
\}"

-- | Softmax shader
softMaxShader :: Text
softMaxShader = "// WGSL soft_max.wgsl\n\
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

-- | RMS normalization with multiplication
rmsNormMulShader :: Text
rmsNormMulShader = "// WGSL rms_norm_mul.wgsl\n\
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

-- | Rotary position embedding
ropeShader :: Text
ropeShader = "// WGSL rope.wgsl\n\
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

-- | Unary operations
unaryShader :: Text
unaryShader = "// WGSL unary.wgsl\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(2) var<uniform> op: u32;\n\
\@group(0) @binding(3) var<uniform> size: u32;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    if (id.x >= size) { return; }\n\
\    \n\
\    let val = input[id.x];\n\
\    var result: f32;\n\
\    \n\
\    switch (op) {\n\
\        case 0u: { result = abs(val); }      // Abs\n\
\        case 1u: { result = -val; }           // Neg\n\
\        case 2u: { result = sign(val); }      // Sgn\n\
\        case 3u: { result = select(0.0, 1.0, val > 0.0); } // Step\n\
\        case 4u: { result = tanh(val); }      // Tanh\n\
\        case 5u: { result = max(0.0, val); }  // Relu\n\
\        case 6u: { result = 1.0 / (1.0 + exp(-val)); } // Sigmoid\n\
\        default: { result = val; }\n\
\    }\n\
\    \n\
\    output[id.x] = result;\n\
\}"

-- | Scale operation
scaleShader :: Text
scaleShader = "// WGSL scale.wgsl\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(2) var<uniform> scale: f32;\n\
\@group(0) @binding(3) var<uniform> size: u32;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    if (id.x >= size) { return; }\n\
\    output[id.x] = input[id.x] * scale;\n\
\}"

-- | Set operation
setShader :: Text
setShader = "// WGSL set.wgsl\n\
\@group(0) @binding(0) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(1) var<uniform> value: f32;\n\
\@group(0) @binding(2) var<uniform> size: u32;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    if (id.x >= size) { return; }\n\
\    output[id.x] = value;\n\
\}"

-- | Set rows operation
setRowsShader :: Text
setRowsShader = "// WGSL set_rows.wgsl\n\
\@group(0) @binding(0) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(1) var<storage, read> values: array<f32>;\n\
\@group(0) @binding(2) var<uniform> dims: vec4<u32>;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let row = id.x / dims.y;\n\
\    let col = id.x % dims.y;\n\
\    \n\
\    if (row >= dims.x || col >= dims.y) { return; }\n\
\    \n\
\    output[row * dims.y + col] = values[row];\n\
\}"

-- | Pad operation
padShader :: Text
padShader = "// WGSL pad.wgsl\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(2) var<uniform> dims: vec4<u32>;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let outRow = id.x / dims.w;\n\
\    let outCol = id.x % dims.w;\n\
\    \n\
\    if (outRow >= dims.z || outCol >= dims.w) { return; }\n\
\    \n\
\    let inRow = outRow - dims.x;\n\
\    let inCol = outCol - dims.y;\n\
\    \n\
\    if (inRow < dims.x || inCol < dims.y) {\n\
\        output[outRow * dims.w + outCol] = 0.0;\n\
\    } else {\n\
\        output[outRow * dims.w + outCol] = input[inRow * dims.w + inCol];\n\
\    }\n\
\}"

-- | Repeat operation
repeatShader :: Text
repeatShader = "// WGSL repeat.wgsl\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(2) var<uniform> dims: vec4<u32>;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let outIdx = id.x;\n\
\    let inIdx = outIdx % dims.x;\n\
\    \n\
\    if (outIdx >= dims.y) { return; }\n\
\    \n\
\    output[outIdx] = input[inIdx];\n\
\}"

-- | Row normalization
rowNormShader :: Text
rowNormShader = "// WGSL row_norm.wgsl\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(2) var<uniform> dims: vec2<u32>;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let row = id.x / dims.y;\n\
\    let col = id.x % dims.y;\n\
\    \n\
\    if (row >= dims.x || col >= dims.y) { return; }\n\
\    \n\
\    // Compute row norm\n\
\    var norm = 0.0;\n\
\    for (var i = 0u; i < dims.y; i++) {\n\
\        let val = input[row * dims.y + i];\n\
\        norm += val * val;\n\
\    }\n\
\    norm = sqrt(norm + 1e-6);\n\
\    \n\
\    output[id.x] = input[id.x] / norm;\n\
\}"

-- | Sum rows operation
sumRowsShader :: Text
sumRowsShader = "// WGSL sum_rows.wgsl\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(2) var<uniform> dims: vec2<u32>;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let row = id.x;\n\
\    \n\
\    if (row >= dims.x) { return; }\n\
\    \n\
\    var sum = 0.0;\n\
\    for (var col = 0u; col < dims.y; col++) {\n\
\        sum += input[row * dims.y + col];\n\
\    }\n\
\    \n\
\    output[row] = sum;\n\
\}"

-- | Solve triangular
solveTriShader :: Text
solveTriShader = "// WGSL solve_tri.wgsl\n\
\@group(0) @binding(0) var<storage, read> matrix: array<f32>;\n\
\@group(0) @binding(1) var<storage, read> rhs: array<f32>;\n\
\@group(0) @binding(2) var<storage, read_write> solution: array<f32>;\n\
\@group(0) @binding(3) var<uniform> size: u32;\n\
\\n\
\@compute @workgroup_size(1)\n\
\fn main() {\n\
\    // Forward substitution for lower triangular\n\
\    for (var i = 0u; i < size; i++) {\n\
\        var sum = rhs[i];\n\
\        for (var j = 0u; j < i; j++) {\n\
\            sum -= matrix[i * size + j] * solution[j];\n\
\        }\n\
\        solution[i] = sum / matrix[i * size + i];\n\
\    }\n\
\}"

-- | SSM convolution
ssmConvShader :: Text
ssmConvShader = "// WGSL ssm_conv.wgsl\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read> kernel: array<f32>;\n\
\@group(0) @binding(2) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(3) var<uniform> dims: vec4<u32>;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let i = id.x;\n\
\    \n\
\    if (i >= dims.x) { return; }\n\
\    \n\
\    var sum = 0.0;\n\
\    for (var j = 0u; j < dims.y; j++) {\n\
\        let idx = i - j;\n\
\        if (idx >= 0) {\n\
\            sum += input[idx] * kernel[j];\n\
\        }\n\
\    }\n\
\    \n\
\    output[i] = sum;\n\
\}"

-- | SSM scan
ssmScanShader :: Text
ssmScanShader = "// WGSL ssm_scan.wgsl\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read> state: array<f32>;\n\
\@group(0) @binding(2) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(3) var<uniform> dims: vec4<u32>;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let i = id.x;\n\
\    \n\
\    if (i >= dims.x) { return; }\n\
\    \n\
\    // SSM scan: h_t = A * h_{t-1} + B * x_t\n\
\    let prevState = select(0.0, state[i - 1], i > 0);\n\
\    output[i] = dims.y * prevState + dims.z * input[i];\n\
\}"

-- | Upscale operation
upscaleShader :: Text
upscaleShader = "// WGSL upscale.wgsl\n\
\@group(0) @binding(0) var<storage, read> input: array<f32>;\n\
\@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n\
\@group(0) @binding(2) var<uniform> dims: vec4<u32>;\n\
\\n\
\@compute @workgroup_size(256)\n\
\fn main(@builtin(global_invocation_id) id: vec3<u32>) {\n\
\    let outRow = id.x / dims.w;\n\
\    let outCol = id.x % dims.w;\n\
\    \n\
\    if (outRow >= dims.z || outCol >= dims.w) { return; }\n\
\    \n\
\    // Nearest neighbor upscale\n\
\    let inRow = outRow / dims.x;\n\
\    let inCol = outCol / dims.y;\n\
\    \n\
\    output[outRow * dims.w + outCol] = input[inRow * dims.y + inCol];\n\
\}"