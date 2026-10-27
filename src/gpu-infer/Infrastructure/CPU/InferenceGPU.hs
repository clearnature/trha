{-# LANGUAGE OverloadedStrings #-}

-- | GPU 前端（WebGPU 生产推理路径）：60 层 GF(27) 前向的 matmul 部分跑 GPU
-- （真实 .sov 权重常驻 storage buffer），wuxing/bypass/head 尾巴复用 CPU 权威函数。
--
-- 正确性：60 层 GPU hidden 与 CPU 权威 'sovereignForwardFullCompactReportL' 的
-- hidden 逐元素一致（benchmarks/webgpu/GpuLayer60Probe.hs，r-mu6s72vg-m8tfr7，
-- token 0/1/3 全 1440 维）。本模块把它封装成生产可用形式。
--
-- 设计：
--   · 'initGpuForward' 一次性上传 60 层 × 4 权重（≈5GB，VRAM 16GB 可容）+
--     建 6 个 kernel（out/gateUp/gated/down/resnorm×2），权重常驻。
--   · 'gpuForwardFull' 每 token：GPU 60 层（每层 7 dispatch，q/christoffel 留 CPU
--     每层计算上传）+ CPU 尾巴（wuxingForward → bypass → rmsnorm → head）。
--   · 初始化 5GB 上传是**一次性成本**（30-60s），推理期不再重传。
--
-- ⚠️ 平台：需要 WebGPU 后端（wgpu-native + Vulkan/radv）；无 GPU 时 'initGpuForward'
-- 返回 Left。GPU 侧一致性已在真机（AMD Navi 44）验证。
module Infrastructure.CPU.InferenceGPU
  ( GpuForward (..)
  , initGpuForward
  , gpuForwardFull
  , gpuForwardHidden
  , gpuForwardFactory
  ) where

import Control.Monad (forM)
import Data.Int (Int32)
import Data.Word (Word32)
import qualified Data.Vector.Storable as VS

import Infrastructure.CPU.SovereignPhase12 (phase12Init, step12, layerStep12)
import Infrastructure.CPU.SovereignFull
  ( CIntLayer (..), SovereignIntWeightsC (..), loadWeightsSovC, loadWuxingFromSov )
import Infrastructure.CPU.SovereignModel (SovereignConfig (..))
import Infrastructure.CPU.SovereignIntrinsic (MixMode (..), christoffelInt)
import Infrastructure.CPU.SovereignTypes
  ( GF27, gf27ToInt, gf27One, mkGF27, mkTrit, tritToInt, plusGF27 )
import Infrastructure.CPU.SovereignWuxingLayer
  ( WuxingConfig (..), WuxingLayerW, wuxingForward )
import Infrastructure.CPU.SovereignGF27 (gf27RmsNorm)
import Infrastructure.CPU.S2Geometry (gf3Shift, getDirection)
import Infrastructure.CPU.Inference (InferenceEngine (..))
import Infrastructure.CPU.GF27SIMD (gf27MatmulCTableVec)

import Infrastructure.WebGPU.Buffer
  ( GpuBuffer, newReadBackBuffer, newStorageBuffer, uploadWords, readWords )
import Infrastructure.WebGPU.Context (Context, withContext)
import Infrastructure.WebGPU.Kernel (Kernel, newKernel, runKernel)

-- | GPU 前向上下文：权重常驻 + kernel 常驻，可跨 token 复用。
data GpuForward = GpuForward
  { gfCtx     :: Context
  , gfConfig  :: SovereignConfig
  , gfWeights :: SovereignIntWeightsC
  , gfKernels :: (Kernel, Kernel, Kernel, Kernel, Kernel, Kernel, Kernel, Kernel)
      -- ^ (out, gateUp, gated, down, resnorm1, resnorm2, qStg1, qStg2)
  , gfLayers  :: [(GpuBuffer, GpuBuffer, GpuBuffer, GpuBuffer)]
      -- ^ 每层 (outW, gateW, upW, downW) 常驻 storage buffer
  , gfQLayers :: [(GpuBuffer, GpuBuffer)]
      -- ^ 每层 (qW[72×1440], proto[12×12×6]) 常驻 —— q/christoffel 权重
  }

dimD, ffD, headsD :: Int
dimD = 1440; ffD = 4320; headsD = 12

-- ═══ q/christoffel kernel（GPU，GpuQProbe r-mu7bnkma 已验证）═══
-- stg1: qt[k] = Σ_j qW[k*D+j] ⊗ (x[j]%3)（整数累加，层2 语义）
-- stg2: out[i] = gf27mul(Σ_k chiral(qt,proto,shift), x[i]%3)，h=i/120, 输出 1440
qKernelWgsl :: String
qKernelWgsl =
  gf27Wgsl ++ unlines
    [ "@group(0) @binding(0) var<storage, read_write> xv: array<u32>;"
    , "@group(0) @binding(1) var<storage, read_write> qWv: array<u32>;"
    , "@group(0) @binding(2) var<storage, read_write> protos: array<u32>;"
    , "@group(0) @binding(3) var<storage, read_write> shiftv: array<u32>;"
    , "@group(0) @binding(4) var<storage, read_write> tgtv: array<u32>;"
    , "@group(0) @binding(5) var<storage, read_write> qt: array<u32>;"
    , "@group(0) @binding(6) var<storage, read_write> out: array<u32>;"
    , "@compute @workgroup_size(64)"
    , "fn stg1(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let k = gid.x;"
    , "  if (k >= 72u) { return; }"
    , "  var acc = 0u;"
    , "  for (var j = 0u; j < 1440u; j++) {"
    , "    acc += gf3mul(qWv[k * 1440u + j], xv[j] % 3u);"
    , "  }"
    , "  qt[k] = acc;"
    , "}"
    , "@compute @workgroup_size(128)"
    , "fn stg2(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let i = gid.x;"
    , "  if (i >= 1440u) { return; }"
    , "  let h = i / 120u;"
    , "  let j = i % 120u;"
    , "  var sumT = 0u;"
    , "  for (var kk = 0u; kk < 6u; kk++) {"
    , "    let q = qt[h * 6u + kk];"
    , "    let p = protos[h * 72u + tgtv[0] * 6u + kk];"
    , "    var d = (q + 3u - p) % 3u;"
    , "    d = (d + shiftv[0]) % 3u;"
    , "    sumT += (d * d) % 3u;"
    , "  }"
    , "  out[i] = gf27mul(sumT, xv[i] % 3u);"
    , "}"
    ]

-- ═══ WGSL 域运算前缀（与 CPU 乘法表逐元素等价：729 组对拍过）═══
gf27Wgsl :: String
gf27Wgsl =
  unlines
    [ "fn gf3add(a: u32, b: u32) -> u32 { return (a + b) % 3u; }"
    , "fn gf3mul(a: u32, b: u32) -> u32 { return (a * b) % 3u; }"
    , "fn gf27mul(aIn: u32, bIn: u32) -> u32 {"
    , "  let a0 = aIn % 3u; let a1 = (aIn / 3u) % 3u; let a2 = aIn / 9u;"
    , "  let b0 = bIn % 3u; let b1 = (bIn / 3u) % 3u; let b2 = bIn / 9u;"
    , "  let c0 = gf3mul(a0, b0);"
    , "  let c1 = gf3add(gf3mul(a0, b1), gf3mul(a1, b0));"
    , "  let c2 = gf3add(gf3add(gf3mul(a0, b2), gf3mul(a1, b1)), gf3mul(a2, b0));"
    , "  let c3 = gf3add(gf3mul(a1, b2), gf3mul(a2, b1));"
    , "  let c4 = gf3mul(a2, b2);"
    , "  let r2 = gf3add(c2, c4);"
    , "  let r1 = gf3add(gf3add(c1, c3), gf3mul(2u, c4));"
    , "  let r0 = gf3add(c0, gf3mul(2u, c3));"
    , "  return r0 + 3u * r1 + 9u * r2;"
    , "}"
    , "fn gf27add(aIn: u32, bIn: u32) -> u32 {"
    , "  let a0 = aIn % 3u; let a1 = (aIn / 3u) % 3u; let a2 = aIn / 9u;"
    , "  let b0 = bIn % 3u; let b1 = (bIn / 3u) % 3u; let b2 = bIn / 9u;"
    , "  return ((a0 + b0) % 3u) + 3u * ((a1 + b1) % 3u) + 9u * ((a2 + b2) % 3u);"
    , "}"
    , "fn gfnorm(aIn: u32) -> u32 {"
    , "  if (aIn == 0u) { return 0u; }"
    , "  return gf27mul(aIn, 3u);"
    , "}"
    ]

matmulWgsl :: Int -> Int -> String
matmulWgsl rows cols =
  gf27Wgsl ++ unlines
    [ "@group(0) @binding(0) var<storage, read_write> Wv: array<u32>;"
    , "@group(0) @binding(1) var<storage, read_write> xv: array<u32>;"
    , "@group(0) @binding(2) var<storage, read_write> ov: array<u32>;"
    , "@compute @workgroup_size(256)"
    , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let i = gid.x;"
    , "  if (i >= " ++ show rows ++ "u) { return; }"
    , "  var acc = 0u;"
    , "  for (var j = 0u; j < " ++ show cols ++ "u; j++) {"
    , "    acc = gf27add(acc, gf27mul(Wv[i * " ++ show cols ++ "u + j], xv[j]));"
    , "  }"
    , "  ov[i] = acc;"
    , "}"
    ]

resnormWgsl :: Int -> String
resnormWgsl n =
  gf27Wgsl ++ unlines
    [ "@group(0) @binding(0) var<storage, read_write> xv: array<u32>;"
    , "@group(0) @binding(1) var<storage, read_write> rv: array<u32>;"
    , "@group(0) @binding(2) var<storage, read_write> ov: array<u32>;"
    , "@compute @workgroup_size(256)"
    , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let i = gid.x;"
    , "  if (i >= " ++ show n ++ "u) { return; }"
    , "  ov[i] = gfnorm(gf27add(xv[i], rv[i]));"
    , "}"
    ]

-- identity copy（最终 hidden 读回用：在 copy kernel 上带 readBack 把 cur 拷到 rb）
copyWgsl :: Int -> String
copyWgsl n =
  gf27Wgsl ++ unlines
    [ "@group(0) @binding(0) var<storage, read_write> xv: array<u32>;"
    , "@group(0) @binding(1) var<storage, read_write> ov: array<u32>;"
    , "@compute @workgroup_size(256)"
    , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let i = gid.x;"
    , "  if (i >= " ++ show n ++ "u) { return; }"
    , "  ov[i] = xv[i];"
    , "}"
    ]

gatedWgsl :: Int -> String
gatedWgsl n =
  gf27Wgsl ++ unlines
    [ "@group(0) @binding(0) var<storage, read_write> g: array<u32>;"
    , "@group(0) @binding(1) var<storage, read_write> u: array<u32>;"
    , "@group(0) @binding(2) var<storage, read_write> o: array<u32>;"
    , "@compute @workgroup_size(256)"
    , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
    , "  let i = gid.x;"
    , "  if (i >= " ++ show n ++ "u) { return; }"
    , "  o[i] = gf27mul(g[i], u[i]);"
    , "}"
    ]

ceilW :: Int -> Word32
ceilW n = fromIntegral ((n + 255) `div` 256)

-- 任意 workgroup_size 的 dispatch 组数（q kernel 用 64/128）
ceilW2 :: Int -> Int -> Word32
ceilW2 n wg = fromIntegral ((n + wg - 1) `div` wg)

flattenV :: VS.Vector Int32 -> [Int]
flattenV = map fromIntegral . VS.toList

-- | 初始化：loadWeightsSovC + 上传 60 层权重到 GPU + 建 kernel。
-- 一次性 5GB 上传（30-60s）；返回 Left 当无 GPU/加载失败。
initGpuForward :: FilePath -> Int -> IO (Either String GpuForward)
initGpuForward sovPath heads = do
  ewc <- loadWeightsSovC sovPath heads
  case ewc of
    Left e -> pure (Left e)
    Right wc -> do
      let cfg = SovereignConfig { scDim = dimD, scDepth = 60, scHeads = heads
                                , scVocab = 1536, scFF = ffD }
      r <- withContext $ \ctx -> do
        kOut  <- newKernel ctx (matmulWgsl dimD dimD) 3 "main"
        kGUp  <- newKernel ctx (matmulWgsl ffD dimD) 3 "main"
        kGated<- newKernel ctx (gatedWgsl ffD) 3 "main"
        kDown <- newKernel ctx (matmulWgsl dimD ffD) 3 "main"
        kRN1  <- newKernel ctx (resnormWgsl dimD) 3 "main"
        kRN2  <- newKernel ctx (resnormWgsl dimD) 3 "main"
        kQ1   <- newKernel ctx qKernelWgsl 7 "stg1"
        kQ2   <- newKernel ctx qKernelWgsl 7 "stg2"
        qPairs <- forM (siwCLayersC wc) $ \cl -> do
          qwb <- newStorageBuffer ctx (72 * dimD * 4)
          pbb <- newStorageBuffer ctx (12 * 12 * 6 * 4)
          uploadWords ctx qwb (map (fromIntegral . tritToInt) (concat (cQProj cl)))
          uploadWords ctx pbb (map (fromIntegral . tritToInt) (concatMap concat (cPrototype cl)))
          pure (qwb, pbb)
        bufSets <- forM (siwCLayersC wc) $ \cl -> do
          wb <- newStorageBuffer ctx (dimD * dimD * 4)
          gb <- newStorageBuffer ctx (ffD * dimD * 4)
          ub <- newStorageBuffer ctx (ffD * dimD * 4)
          db <- newStorageBuffer ctx (dimD * ffD * 4)
          uploadWords ctx wb (map fromIntegral (flattenV (cOutProj cl)))
          uploadWords ctx gb (map fromIntegral (flattenV (cGateProj cl)))
          uploadWords ctx ub (map fromIntegral (flattenV (cUpProj cl)))
          uploadWords ctx db (map fromIntegral (flattenV (cDownProj cl)))
          pure (wb, gb, ub, db)
        pure (GpuForward ctx cfg wc (kOut, kGUp, kGated, kDown, kRN1, kRN2, kQ1, kQ2) bufSets qPairs)
      pure (Right r)

-- | GPU 60 层前向 → 隐藏态（不加尾巴；对拍用）。每 token 独立。
-- GPU-only：x 全程在 GPU（cur/nxt 双 buffer 轮换），q 走 GPU kernel，60 层结束
-- 一次性读回最终 hidden。
gpuForwardHidden
  :: GpuForward -> SovereignIntWeightsC -> [Int] -> IO (Either String [[GF27]])
gpuForwardHidden gfw wc [tok] = do
  let ctx = gfCtx gfw
      (kOut, kGUp, kGated, kDown, kRN1, kRN2, kQ1, kQ2) = gfKernels gfw
  -- 激活 buffer（每调用新建，避免跨调用状态）；生产化可常驻
  xb <- newStorageBuffer ctx (dimD * 4)
  qb <- newStorageBuffer ctx (dimD * 4)
  qtb<- newStorageBuffer ctx (72 * 4)
  stb<- newStorageBuffer ctx 4                        -- shift 每层传
  tgb<- newStorageBuffer ctx 4                        -- target 每层传
  a1 <- newStorageBuffer ctx (dimD * 4)
  gf <- newStorageBuffer ctx (ffD * 4)
  uf <- newStorageBuffer ctx (ffD * 4)
  ged<- newStorageBuffer ctx (ffD * 4)
  nxt<- newStorageBuffer ctx (dimD * 4)
  rb <- newReadBackBuffer ctx (dimD * 4)
  let embedRow = map gf27ToInt (siwCEmbed wc !! (tok `mod` length (siwCEmbed wc)))
  uploadWords ctx xb (map fromIntegral embedRow)
  let cls = siwCLayersC wc
      pairs = [ pr | (_, pr) <- map layerStep12 (take (length cls) (iterate step12 phase12Init)) ]
      steps = zip3 [0 :: Int ..] (zip (gfLayers gfw) cls) pairs
  final <- goLayers ctx kOut kGUp kGated kDown kRN1 kRN2 kQ1 kQ2
             qb qtb stb tgb a1 gf uf ged nxt rb
             (zip (gfQLayers gfw) steps)
             xb nxt          -- cur=xb（embed 已上传）, nxt=a2
  kCopy <- newKernel ctx (copyWgsl dimD) 2 "main"
  _ <- runKernel ctx kCopy [final, xb] (ceilW dimD, 1, 1) (Just (final, rb, dimD))
  x2 <- readWords ctx rb dimD
  pure (Right [map (mkGF27 . fromIntegral) x2])
gpuForwardHidden _ _ _ = pure (Left "gpuForwardHidden: 只支持单 token")

-- | 完整前向：GPU 60 层 + CPU 尾巴（wuxingForward / bypass / rmsnorm / head）。
-- 返回每 token 的 headLogits（与 'sovereignForwardFullCompact' 同形状）。
gpuForwardFull
  :: GpuForward -> SovereignConfig -> SovereignIntWeightsC
  -> WuxingConfig -> WuxingLayerW
  -> [Int] -> IO (Either String [[GF27]])
gpuForwardFull gfw cfg wc wcfg wl tokenIds = do
  hiddens <- gpuForwardHidden gfw wc tokenIds
  case hiddens of
    Left e -> pure (Left e)
    Right hidden -> do
      let gamma = replicate (scDim cfg) (mkGF27 1)
          voc = scVocab cfg
          dim = scDim cfg
          bypassRow tok = map (mkGF27 . fromIntegral)
                          (VS.toList (VS.slice ((tok `mod` voc) * dim) dim (siwCBypassV wc)))
          headV = siwCLmHeadV wc
          reports = [ wuxingForward wcfg wl h | h <- hidden ]
          wxed = [ case r of (h', _, _, _) -> h' | r <- reports ]
          bypassed = [ zipWith plusGF27 h (bypassRow t) | (h, t) <- zip wxed tokenIds ]
          normed = map (gf27RmsNorm gamma) bypassed
      headLogits <- mapM (\row -> do
                            let xv = VS.fromList (map (fromIntegral . gf27ToInt) row)
                            rv <- gf27MatmulCTableVec voc dim headV xv
                            pure (map (mkGF27 . fromIntegral) (VS.toList rv)))
                         normed
      pure (Right headLogits)

-- ═══ 60 层 GPU 循环（GPU-only 闭环）═══
-- steps 里每层的权重已含 (outW,gateW,upW,downW)；q 权重 (qW,proto) 单独传。
-- cur/nxt 双 buffer 轮换：每层把 x2 写进 nxt，然后交换 cur/nxt 作为下一层输入。
goLayers
  :: Context
  -> Kernel -> Kernel -> Kernel -> Kernel -> Kernel -> Kernel -> Kernel -> Kernel
  -> GpuBuffer -> GpuBuffer -> GpuBuffer -> GpuBuffer -> GpuBuffer
  -> GpuBuffer -> GpuBuffer -> GpuBuffer -> GpuBuffer -> GpuBuffer
  -> [( (GpuBuffer, GpuBuffer)
      , (Int, ((GpuBuffer, GpuBuffer, GpuBuffer, GpuBuffer), CIntLayer), (Int, Int)) )]
  -> GpuBuffer -> GpuBuffer -> IO GpuBuffer
goLayers ctx kOut kGUp kGated kDown kRN1 kRN2 kQ1 kQ2
         qb qtb stb tgb a1 gf uf ged nxt rb
         qsteps cur0 nxt0 = go cur0 nxt0 qsteps
  where
    go cur _ [] = pure cur
    go cur nxt ((qbufs, (_li, ((wb, gb, ub, db), cl), (cell, target))) : rest) = do
      let (qwb, pbb) = qbufs
      -- shift/target 每层上传（2 u32）
      uploadWords ctx stb [fromIntegral (gf3Shift cell (getDirection cell target))]
      uploadWords ctx tgb [fromIntegral target]
      -- q：stg1 = qW ⊗ cur → qt；stg2 = mix → qb
      _ <- runKernel ctx kQ1 [cur, qwb, pbb, stb, tgb, qtb, qb] (ceilW2 72 64, 1, 1) Nothing
      _ <- runKernel ctx kQ2 [cur, qwb, pbb, stb, tgb, qtb, qb] (ceilW2 1440 128, 1, 1) Nothing
      -- out = outW ⊗ qb → a1
      _ <- runKernel ctx kOut [wb, qb, a1] (ceilW dimD, 1, 1) Nothing
      -- rms1：a1 = norm(cur + out_a1)
      _ <- runKernel ctx kRN1 [cur, a1, a1] (ceilW dimD, 1, 1) Nothing
      -- gate/up
      _ <- runKernel ctx kGUp [gb, a1, gf] (ceilW ffD, 1, 1) Nothing
      _ <- runKernel ctx kGUp [ub, a1, uf] (ceilW ffD, 1, 1) Nothing
      _ <- runKernel ctx kGated [gf, uf, ged] (ceilW ffD, 1, 1) Nothing
      -- down = downW ⊗ ged → nxt
      _ <- runKernel ctx kDown [db, ged, nxt] (ceilW dimD, 1, 1) Nothing
      -- rms2：nxt = norm(a1 + down_nxt)
      _ <- runKernel ctx kRN2 [a1, nxt, nxt] (ceilW dimD, 1, 1) Nothing
      -- 轮换：下一层 x = nxt；旧 cur 变 nxt
      go nxt cur rest

-- (GF3Shift / getDirection import 在文件头)

-- | 纯工厂：只返回 GPU 前向函数句柄（不带 LLMAdapter，规避共享 src 双类型）。
-- 调用方（trha-api）把它传给 'LLM.Adapter.Interface.createCPUAdapterWith'。
-- wuxing 权重自己从 .sov 载入（与 engine 内部时序解耦）。
gpuForwardFactory :: FilePath -> Int -> IO (Either String ([Int] -> IO (Either String [[Int]])))
gpuForwardFactory path heads = do
  gpuRes <- initGpuForward path heads
  case gpuRes of
    Left err -> pure (Left err)
    Right gfw -> do
      wlRes <- loadWuxingFromSovL path heads 4 3
      case wlRes of
        Left err -> pure (Left err)
        Right wl -> pure (Right (\tok -> do
          r <- gpuForwardFull gfw (gfConfig gfw) (gfWeights gfw) (wuCfg heads) wl tok
          pure (map (map gf27ToInt) <$> r)))

-- 直接从 trha-llm 拿 wuxing 加载器（原名 loadWuxingFromSov）
loadWuxingFromSovL = loadWuxingFromSov

-- 构造 wuxing config（与 engine 一致：1440/12/4/6/3）
wuCfg :: Int -> WuxingConfig
wuCfg heads = WuxingConfig { wcDim = 1440, wcHeads = heads, wcSteps = 4, wcHex = 6, wcTrit = 3 }
