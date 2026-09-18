{-# LANGUAGE OverloadedStrings #-}

-- | GPU 60 层前向探针：真实 .sov 全 60 层权重常驻 storage buffer，
-- 逐层 5 dispatch（out→rms1→gate/up→gated→down→rms2）。
-- q/christoffel（0.014ms/层）留 CPU：每层「上层的 x2CPU」直接算 q（无需回读）。
-- 60 层后 hidden 与 CPU 'sovereignForwardFullCompactReportL'（wuxing 前层 hidden）逐元素对拍。
--
-- 流转（每层循环体）：
--   xInCPU（首层 = embed，否则 = 上层 x2CPU）→ q = christoffel(cell,target,xInCPU)
--   upload xb, qb → out(W⊗q)=a1 → rms1(x+a1)=a1 → gate/up → gated → down=a2
--   → rms2(a1+a2)=a2，且带 readBack (a2, rb) 拿回 x2CPU 作为下一层输入
--
-- 用法：cabal run trha-webgpu-layer60probe [sovPath]
--   TRHA_LAYERS=n 只跑前 n 层（默认 60）
--   TRHA_TOKEN=t  用 token t（默认 0；embed 查 siwCEmbed）
module Main (main) where

import Control.Monad (forM, forM_)
import Data.List (foldl')
import Data.Word (Word32)
import Data.Int (Int32)
import GHC.Clock (getMonotonicTime)
import System.Environment (getArgs, lookupEnv)

import Infrastructure.CPU.SovereignPhase12 (phase12Init, step12, layerStep12)
import Infrastructure.CPU.SovereignFull
  ( CIntLayer (..), SovereignIntWeightsC, siwCLayersC, siwCEmbed, loadWeightsSovC
  , loadWuxingFromSov, sovereignForwardFullCompactReportL )
import Infrastructure.CPU.SovereignModel (SovereignConfig (..))
import Infrastructure.CPU.SovereignIntrinsic (MixMode (..), christoffelInt)
import Infrastructure.CPU.SovereignTypes (GF27, gf27ToInt, mkGF27, mkTrit, Trit, tritToInt, mulGF27)
import Infrastructure.CPU.SovereignGF27 (gf27Add, gf27Matmul, gf27RmsNorm)
import Infrastructure.CPU.SovereignWuxingLayer (WuxingConfig (..), WuxingLayerW)
import qualified Data.Vector.Storable as VS

import Infrastructure.WebGPU.Buffer (newReadBackBuffer, newStorageBuffer, uploadWords, GpuBuffer (..))
import Infrastructure.WebGPU.Context (withContext, Context (..))
import Infrastructure.WebGPU.Kernel (newKernel, runKernel, Kernel (..))

dimD, ffD, headsD :: Int
dimD = 1440; ffD = 4320; headsD = 12

cfg0 :: SovereignConfig
cfg0 = SovereignConfig { scDim = dimD, scDepth = 60, scHeads = headsD, scVocab = 1536, scFF = ffD }

-- ═══════ WGSL（与单层探针同源：域运算前缀 + 4 类 kernel）═══════
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

type LayerBufs = (GpuBuffer, GpuBuffer, GpuBuffer, GpuBuffer)  -- out, gate, up, down

-- 一层权重（Trit）→ [Int]（已由 loadWeightsSovC 扁平成 VS.Vector Int32）
flattenV :: VS.Vector Int32 -> [Int]
flattenV = map fromIntegral . VS.toList

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  nL <- maybe 60 id . (>>= readMay) <$> lookupEnv "TRHA_LAYERS"
  tok <- maybe 0 id . (>>= readMay) <$> lookupEnv "TRHA_TOKEN"
  putStrLn ("=== GPU 60 层前向探针（" ++ show nL ++ " 层，token " ++ show tok ++ "）===")
  ew <- loadWeightsSovC sov headsD
  case ew of
    Left e -> putStrLn ("loadWeightsSovC ✗: " ++ e)
    Right wc -> do
      -- CPU 权威参照：reportL 的 hidden = layerIntrinsic27C fold 直接产出（非复刻）
      ewl <- loadWuxingFromSov sov headsD 4 3
      case ewl of
        Left e -> putStrLn ("loadWuxingFromSov ✗: " ++ e)
        Right wl -> do
          cp <- sovereignForwardFullCompactReportL cfg0 wc (wuCfg12 headsD) wl [tok]
          let want = map gf27ToInt (head (thd3 cp))
          putStrLn ("CPU 权威 hidden（reportL 60 层）前 6 维: " ++ show (take 6 want))
          runGpu wc want nL tok

runGpu :: SovereignIntWeightsC -> [Int] -> Int -> Int -> IO ()
runGpu wc want nL tok = withContext $ \ctx -> do
        kOut  <- newKernel ctx (matmulWgsl dimD dimD) 3 "main"
        kGUp  <- newKernel ctx (matmulWgsl ffD dimD) 3 "main"
        kGated<- newKernel ctx (gatedWgsl ffD) 3 "main"
        kDown <- newKernel ctx (matmulWgsl dimD ffD) 3 "main"
        kRN1  <- newKernel ctx (resnormWgsl dimD) 3 "main"
        kRN2  <- newKernel ctx (resnormWgsl dimD) 3 "main"

        -- 60 层权重 buffer（每层 4 个，常驻）
        let cls = take nL (siwCLayersC wc)
        bufSets <- forM cls $ \cl -> do
          wb <- newStorageBuffer ctx (dimD * dimD * 4)
          gb <- newStorageBuffer ctx (ffD * dimD * 4)
          ub <- newStorageBuffer ctx (ffD * dimD * 4)
          db <- newStorageBuffer ctx (dimD * ffD * 4)
          uploadWords ctx wb (map fromIntegral (flattenV (cOutProj cl)))
          uploadWords ctx gb (map fromIntegral (flattenV (cGateProj cl)))
          uploadWords ctx ub (map fromIntegral (flattenV (cUpProj cl)))
          uploadWords ctx db (map fromIntegral (flattenV (cDownProj cl)))
          pure (wb, gb, ub, db)

        -- 激活 buffer
        xb <- newStorageBuffer ctx (dimD * 4)
        qb <- newStorageBuffer ctx (dimD * 4)
        a1 <- newStorageBuffer ctx (dimD * 4)
        gf <- newStorageBuffer ctx (ffD * 4)
        uf <- newStorageBuffer ctx (ffD * 4)
        ged<- newStorageBuffer ctx (ffD * 4)
        a2 <- newStorageBuffer ctx (dimD * 4)
        rb <- newReadBackBuffer ctx (dimD * 4)

        -- 首层输入：embed（token 行）
        let embedRow = map gf27ToInt (siwCEmbed wc !! (tok `mod` length (siwCEmbed wc)))
        uploadWords ctx xb (map fromIntegral embedRow)

        -- 每层 (cell,target) 序列
        let pairs = [ pr | (_, pr) <- map layerStep12 (take nL (iterate step12 phase12Init)) ]
        t0 <- getMonotonicTime
        xInCPU <- goLayers ctx
          kOut kGUp kGated kDown kRN1 kRN2
          xb qb a1 gf uf ged a2 rb
          (zip3 [0 :: Int ..] (zip bufSets cls) pairs)
          embedRow
        t1 <- getMonotonicTime
        putStrLn ("GPU " ++ show nL ++ " 层墙钟: " ++ show ((t1 - t0) * 1000) ++ " ms（含每层 CPU q + 上传）")
        putStrLn ("GPU 末层 hidden 前 6 维: " ++ show (take 6 xInCPU))
        putStrLn ("（对拍参照 = reportL 60 层 hidden，与 TRHA_LAYERS 无关）")
        let bad = [ (i, w, c) | (i, (w, c)) <- zip [0 :: Int ..] (zip xInCPU want), w /= c ]
        if null bad
          then putStrLn "✓ GPU 60 层 hidden 与 CPU 权威（reportL）逐元素一致 —— 全链 GPU 化可行"
          else putStrLn ("✗ 不一致 " ++ show (length bad) ++ " 处（前 6 例: " ++ show (take 6 bad) ++ "）")
readMay :: String -> Maybe Int
readMay s = case reads s of [(n, "")] -> Just n; _ -> Nothing

-- | 逐层循环：返回最后一层 x2（CPU 侧，供与 CP 对拍）。
goLayers
  :: Context
  -> Kernel -> Kernel -> Kernel -> Kernel -> Kernel -> Kernel
  -> GpuBuffer -> GpuBuffer -> GpuBuffer -> GpuBuffer -> GpuBuffer -> GpuBuffer
  -> GpuBuffer -> GpuBuffer
  -> [(Int, ((GpuBuffer, GpuBuffer, GpuBuffer, GpuBuffer), CIntLayer), (Int, Int))]
  -> [Int] -> IO [Int]
goLayers ctx kOut kGUp kGated kDown kRN1 kRN2
         xb qb a1 gf uf ged a2 rb steps x0 = go x0 steps
  where
    go xIn [] = pure xIn
    go xIn ((li, ((wb, gb, ub, db), cl), (cell, target)) : rest) = do
      -- 1. q = christoffelInt（CPU）：输入 = 当前 x（GF27）
      let qIn = christoffelInt MixGF27 headsD (cQProj cl) (cPrototype cl) cell target
                  (map (mkTrit . fromIntegral) xIn)
      _ <- pure li
      -- 2. 上传 x（当前输入）与 q
      uploadWords ctx xb (map fromIntegral xIn)
      uploadWords ctx qb (map fromIntegral qIn)
      -- 3. out：a1 = outW ⊗ q
      _ <- runKernel ctx kOut [wb, qb, a1] (ceilW dimD, 1, 1) Nothing
      -- 4. rms1：a1 = norm(x + a1)
      _ <- runKernel ctx kRN1 [xb, a1, a1] (ceilW dimD, 1, 1) Nothing
      -- 5. gate/up：gf/uf = gateW/upW ⊗ a1
      _ <- runKernel ctx kGUp [gb, a1, gf] (ceilW ffD, 1, 1) Nothing
      _ <- runKernel ctx kGUp [ub, a1, uf] (ceilW ffD, 1, 1) Nothing
      -- 6. gated：ged = gf ⊗ uf
      _ <- runKernel ctx kGated [gf, uf, ged] (ceilW ffD, 1, 1) Nothing
      -- 7. down：a2 = downW ⊗ ged
      _ <- runKernel ctx kDown [db, ged, a2] (ceilW dimD, 1, 1) Nothing
      -- 8. rms2：a2 = norm(a1 + a2)，并带回 x2CPU（供下层 q 与最终对拍）
      x2 <- runKernel ctx kRN2 [a1, a2, a2] (ceilW dimD, 1, 1) (Just (a2, rb, dimD))
      go (map fromIntegral x2) rest

wuCfg12 :: Int -> WuxingConfig
wuCfg12 heads = WuxingConfig { wcDim = dimD, wcHeads = heads, wcSteps = 4, wcHex = 6, wcTrit = 3 }

thd3 :: (a, b, c) -> c
thd3 (_, _, c) = c

timeIt :: IO a -> IO (a, Double)
timeIt act = do
  t0 <- getMonotonicTime
  r <- act
  t1 <- getMonotonicTime
  pure (r, (t1 - t0) * 1000)
