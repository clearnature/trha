{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | 完整链路：embedding → **60 层 GF(27)（十二律相位驱动）** → **一步五行推理** →
-- content bypass → final norm → lm_head。
--
-- 三段各自的出处：
--
-- > 层推进   SovereignPhase12   损-益交替（Christoffel 螺旋 ×2 mod 9 的模 3 投影）
-- >                             + 每 12 步一次桥（仲吕对齐）
-- > 层体     SovereignGF27      GF(27) 整链（MixGF27 + gf27Matmul/RmsNorm/SwiGLU）
-- > 推理     SovereignWuxingLayer  T⁶ 环面上 4 步「六节点 × 三值」因果推理
--
-- 这一层刻意不做维度变换：`layerIntrinsic27At` 与 `wuxingForward` 都吃/吐
-- `[GF27]`，所以可以直接串联。
module Infrastructure.CPU.SovereignFull
  ( sovereignForwardFull
  , fullChainReport
  , forwardStreaming
  , forwardStreamingDir
  ) where

import Infrastructure.CPU.SovereignGF27
  ( embed27
  , gf27Matmul
  , gf27RmsNorm
  , layerIntrinsic27At
  )
import qualified Infrastructure.CPU.SovereignTypes as ST
import Infrastructure.CPU.SovereignTypes (GF27, Trit, mkTrit, tritToInt)
import Infrastructure.CPU.SovereignIntrinsic (SovereignIntWeights(..), SovereignIntLayer(..))
import Infrastructure.CPU.SovereignModel (SovereignConfig(..), defaultMonopolePrototype)
import Infrastructure.CPU.SovereignPhase12 (layerStep12, phase12Init, step12)
import Infrastructure.CPU.SOV3 (indexZip, sovLookup, sovSlice, unpackTritsInt)
import Control.Exception (evaluate)
import Data.List (foldl')
import qualified Data.ByteString as BS
import Infrastructure.CPU.SovereignWuxingLayer
  ( T6State
  , WuxingConfig
  , WuxingLayerW
  , wuxingForward
  )

-- | 取四元组首项（'wuxingForward' 的返回形状是 4 元）。
firstOf4 :: (a, b, c, d) -> a
firstOf4 (a, _, _, _) = a

-- | 全链路前向，返回每个 token 的 logits（GF(27) 元素，∈ [0,26]）。
sovereignForwardFull
  :: SovereignConfig
  -> SovereignIntWeights
  -> WuxingConfig
  -> WuxingLayerW
  -> [Int]
  -> [[GF27]]
sovereignForwardFull cfg w wcfg wl tokenIds = map headLogits normed
  where
    dim   = scDim cfg
    gamma = replicate dim ST.gf27One

    -- ① 60 层，由真实十二律相位驱动（每 12 步一次桥）
    pairs = [ pr | (_, pr) <- map layerStep12 (take (scDepth cfg) (iterate step12 phase12Init)) ]
    embedded = embed27 cfg w tokenIds
    hidden = foldl (\hs (i, pr) -> map (layerIntrinsic27At cfg (siwLayers w !! i) pr) hs)
                   embedded (zip [0 ..] pairs)

    -- ② 一步五行推理（T⁶ 环面上的四步因果链）
    wxed = [ firstOf4 (wuxingForward wcfg wl h) | h <- hidden ]

    -- ③ bypass → final norm → lm_head
    bypassed = [ zipWith ST.plusGF27 h (map ST.embedGF3 (tableRow (siwContentBypass w) t))
               | (h, t) <- zip wxed tokenIds ]
    normed = map (gf27RmsNorm gamma) bypassed
    headLogits = gf27Matmul (siwLmHead w)
    tableRow table tok = take dim (table !! (tok `mod` length table) ++ repeat (mkTrit 0))

-- | 把整个矩阵强制到完全求值（deep-force）。
--
-- ⚠️ 这一步是流式前向**内存安全的关键**。惰性求值下 `readMat` 返回的是一张 thunk 图：
-- 每层的 `ByteString` 会被闭包捕获，`[4320,1440]` 又是 6.2M 个未求值的 `Float`/`Int`。
-- 若不在读入时立即强制，60 层的权重会全部滞留 —— 实测把进程撑到 **54 GB** 并触发
-- 系统级 OOM（`global_oom`，killed `trha-test`, anon-rss 54047760 kB）。
forceMat :: [[Trit]] -> [[Trit]]
forceMat m = forceRows 0 m `seq` m
  where
    forceRows :: Int -> [[Trit]] -> Int
    forceRows !acc []       = acc
    forceRows !acc (r : rs) = forceRows (acc + forceRow r) rs
    forceRow :: [Trit] -> Int
    forceRow = foldl' (\a t -> a + tritToInt t) 0

-- | 把向量强制到完全求值，并返回它本身。
--
-- 用 'length' 而非 @foldl' (+) 0@：元素是 newtype 包裹的 'Int'（零开销），
-- spine 走完即已完全求值，不必真的做一次 O(n) 加法（那是纯浪费）。
forceVec :: [GF27] -> [GF27]
forceVec v = length v `seq` v

-- | 流式全 60 层：**逐层从 checkpoint 目录读真实权重**，用完即弃。
--
-- 内存边界：每层读 5 个矩阵（最大 `[4320,1440]`，约 6.2M 元素）并**立即强制**，
-- 跑完该层后上一层即可回收。峰值约 1–2 GB，而非一次性载入的几十 GB。
--
-- 为什么需要它：全 60 层的权重字节约 242 MB，但转成 Haskell 的 `[[Int]]` 装箱表示
-- 会膨胀到几十 GB —— 一次性载入放不下。这里改成每层读 5 个矩阵、跑完该层就释放。
--
-- 目录约定（见 M19）：`data/23 + 5k + {0..4}` 是 `layers.k` 的
-- `christoffel.q_proj / christoffel.out_proj / ffn.gate_proj / ffn.up_proj / ffn.down_proj`。
--
-- **两种来源**：直接吃 @.sov@（推荐，见 'forwardStreaming'），
-- 或吃已解包的目录（'forwardStreamingDir'，保留用于对拍）。
forwardStreaming
  :: FilePath            -- ^ @.sov@ 文件路径
  -> SovereignConfig
  -> [Int]               -- ^ token ids
  -> IO (Either String [GF27])
forwardStreaming sovPath cfg tokenIds = do
  img <- BS.readFile sovPath
  let idx = indexZip img
  runStreaming
    (\i -> case sovLookup idx ("/data/" ++ show i) of
             Just e  -> pure (sovSlice img e)
             Nothing -> pure BS.empty)
    cfg tokenIds

-- | 目录版（保留作对拍基线）：逐层从 @dir/data/N@ 读。
forwardStreamingDir
  :: FilePath            -- ^ 含 @data/N@ 的目录
  -> SovereignConfig
  -> [Int]
  -> IO (Either String [GF27])
forwardStreamingDir dir cfg tokenIds = do
  runStreaming (\i -> BS.readFile (dir ++ "/data/" ++ show i)) cfg tokenIds

-- | 流式骨架：@fetch@ 给出第 @i@ 个条目的字节，其余逻辑与来源无关。
runStreaming
  :: (Int -> IO BS.ByteString)   -- ^ 按 @data/N@ 的序号取字节
  -> SovereignConfig
  -> [Int]
  -> IO (Either String [GF27])
runStreaming fetch cfg tokenIds = do
  let dim   = scDim cfg
      heads = scHeads cfg
      ff    = scFF cfg
      hex   = 6
      proto = map (map (map mkTrit)) (defaultMonopolePrototype heads)
      chunk n xs = case xs of
        [] -> []
        _  -> take n xs : chunk n (drop n xs)
      readMat r c i = do
        bs <- fetch i
        -- evaluate + forceMat：在 IO 动作内就把整张矩阵算完，之后 bs 可被 GC。
        -- 直接用 unpackTritsInt，省掉 Float 装箱与 map round。
        evaluate (forceMat (map (map mkTrit)
                             (chunk c (take (r * c) (unpackTritsInt bs (r * c))))))
  -- 相位一次算好（60 个），不要每层用 `iterate !! k` 重建
  let phases = [ pr | (_, pr) <- map layerStep12 (take (scDepth cfg) (iterate step12 phase12Init)) ]
  -- 逐层推进：每层读 5 个矩阵 → 立即强制 → 跑该层 → 强制输出 → 丢弃
  let go !k x
        | k >= scDepth cfg = pure (Right x)
        | otherwise = do
            let b = 23 + 5 * k
            q  <- readMat (heads * 6) dim b
            o' <- readMat dim dim (b + 1)
            g  <- readMat ff dim (b + 2)
            u  <- readMat ff dim (b + 3)
            d  <- readMat dim ff (b + 4)
            let lyr = SovereignIntLayer q o' g u d proto
                (cell, target) = phases !! k
            -- ⚠️ 必须 evaluate + forceVec：只写 `x' `seq` ...` 仅强制到 WHNF，
            -- 列表元素仍是 thunk，会层层累积（这正是 54 GB 的成因）。
            x' <- evaluate (forceVec (layerIntrinsic27At cfg lyr (cell, target) x))
            go (k + 1) x'
  -- 起点取 embedding 的前 dim 维（token_emb.weight 是 [1536,1440]）
  bs0 <- fetch 0
  let tokE = chunk dim (take (8 * dim) (unpackTritsInt bs0 (8 * dim)))
      embedded = [ take dim (row ++ repeat ST.gf27Zero)
                 | tok <- tokenIds, let row = map ST.mkGF27 (tokE !! (tok `mod` length tokE)) ]
  case embedded of
    [] -> pure (Right [])
    (x0 : _) -> go 0 x0

-- | 诊断版：额外返回五行推理的相位状态、四步链与可达标记。
fullChainReport
  :: SovereignConfig
  -> SovereignIntWeights
  -> WuxingConfig
  -> WuxingLayerW
  -> [Int]
  -> ([[GF27]], [T6State], [[[(Int, Int)]]], [[Bool]])
fullChainReport cfg w wcfg wl tokenIds =
  ( map headLogits normed
  , tmstates
  , chains
  , okss )
  where
    dim   = scDim cfg
    gamma = replicate dim ST.gf27One
    pairs = [ pr | (_, pr) <- map layerStep12 (take (scDepth cfg) (iterate step12 phase12Init)) ]
    embedded = embed27 cfg w tokenIds
    hidden = foldl (\hs (i, pr) -> map (layerIntrinsic27At cfg (siwLayers w !! i) pr) hs)
                   embedded (zip [0 ..] pairs)
    reports = [ wuxingForward wcfg wl h | h <- hidden ]
    wxed    = [ h | (h, _, _, _) <- reports ]
    tmstates = [ st | (_, st, _, _) <- reports ]
    chains   = [ ch | (_, _, ch, _) <- reports ]
    okss     = [ os | (_, _, _, os) <- reports ]
    bypassed = [ zipWith ST.plusGF27 h (map ST.embedGF3 (tableRow (siwContentBypass w) t))
               | (h, t) <- zip wxed tokenIds ]
    normed = map (gf27RmsNorm gamma) bypassed
    headLogits = gf27Matmul (siwLmHead w)
    tableRow table tok = take dim (table !! (tok `mod` length table) ++ repeat (mkTrit 0))
