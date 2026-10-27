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
  , sovereignForwardFullC
  , sovereignForwardFullCompact
  , sovereignForwardFullCompactReport
  , sovereignForwardFullCompactReportL
  , cIntLayer
  , CIntLayer(..)
  , SovereignIntWeightsC(..)
  , loadWeightsSovC
  , fullChainReport
  , forwardStreaming
  , forwardStreamingDir
  , forwardStreamingFull
  , runStreamingFull
  , runStreamingFullWithB1
  , forwardStreamingFullB1
  , brainStepToken
  , loadWuxingFromSov
  , loadWeightsFromSov
  ) where

import Infrastructure.CPU.SovereignGF27
  ( embed27
  , gf27Add
  , gf27Matmul
  , gf27RmsNorm
  , layerIntrinsic27At
  )
import qualified Infrastructure.CPU.SovereignTypes as ST
import Infrastructure.CPU.SovereignTypes (GF27, Trit, mkTrit, tritToInt)
import Infrastructure.CPU.SovereignIntrinsic
  ( MixMode(..)
  , SovereignIntWeights(..)
  , SovereignIntLayer(..)
  , christoffelInt
  )
import Infrastructure.CPU.SovereignModel (SovereignConfig(..), defaultMonopolePrototype)
import Infrastructure.CPU.SovereignPhase12 (layerStep12, phase12Init, step12)
import Infrastructure.CPU.SOV3 (indexZip, sovLookup, sovSlice, unpackTritsInt)
import Control.Exception (evaluate)
import Data.List (foldl')
import qualified Data.ByteString as BS
import Data.Int (Int32)
import Infrastructure.CPU.GF3Intrinsic (gf27Mul)
import Infrastructure.CPU.B1Window (b1ApplyWindow)
import Infrastructure.CPU.SovereignWuxingLayer
  ( T6State
  , WuxingConfig
  , WuxingLayerW(..)
  , argMaxIdx
  , wuxingForward
  )
import qualified Data.Vector.Storable as VS
import Infrastructure.CPU.GF27SIMD (gf27MatmulCTableVec)

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

-- | **C 双表常驻指针版层权重**：'SovereignIntLayer' 的 4 个 matmul 权重预转成
-- @VS.Vector Int32@ 行优先扁平（一次转换常驻内存，FFI 只传指针，不再每轮
-- fromIntegral 拷贝）。q_proj/prototype 保留 Haskell 侧（[heads×6, dim] 极小，
-- 'christoffelInt' 吃 [[Trit]]）。数学与 'gf27Matmul' 完全同构（同一 logT/expT 双表）。
data CIntLayer = CIntLayer
  { cQProj      :: [[Trit]]          -- ^ [heads*6 × dim]（christoffelInt 输入）
  , cPrototype  :: [[[Trit]]]        -- ^ [heads][to_cell][6]
  , cOutProj    :: VS.Vector Int32   -- ^ [dim × dim]
  , cGateProj   :: VS.Vector Int32   -- ^ [ff × dim]
  , cUpProj     :: VS.Vector Int32   -- ^ [ff × dim]
  , cDownProj   :: VS.Vector Int32   -- ^ [dim × ff]
  } deriving (Show, Eq)

-- | [[Trit]] 行优先矩阵 → 扁平 int32 向量（元素 ∈ {0,1,2}）。
tritMatToV :: [[Trit]] -> VS.Vector Int32
tritMatToV = VS.fromList . map (fromIntegral . tritToInt) . concat

-- | 转换 'SovereignIntLayer' → 'CIntLayer'（60 层 × 4 矩阵，一次转换常驻）。
-- 内存：每层 out 8.3MB + gate/up 各 24.9MB + down 24.9MB ≈ 83MB → 60 层 ≈ 5GB，
-- 对比装箱 [[Trit]] 的 ~40GB 峰值（SovereignFull.hs:291 注释），紧凑布局同时
-- 解决预载整包的 OOM 风险（本机 CommitLimit 32GB）。
cIntLayer :: SovereignIntLayer -> CIntLayer
cIntLayer lyr = CIntLayer
  { cQProj     = silQProj    lyr
  , cPrototype = silPrototype lyr
  , cOutProj   = tritMatToV (silOutProj  lyr)
  , cGateProj  = tritMatToV (silGateProj lyr)
  , cUpProj    = tritMatToV (silUpProj   lyr)
  , cDownProj  = tritMatToV (silDownProj lyr)
  }

-- | C 双表版**单层前向**（与 'layerIntrinsic27At' 逐元素同构，IO 因 FFI 调用）：
-- q 投影走 Haskell 'christoffelInt'；out/gate/up/down 四个 matmul 走
-- 'gf27MatmulCTableVec'（27×27 乘法表 + 加法表 + OpenMP 行间并行）。
-- 激活每次调用转 @VS.Vector@（1440/4320 元素，量级小，开销可忽略）。
layerIntrinsic27C
  :: SovereignConfig
  -> CIntLayer           -- ^ C 双表版（q_proj 原样 + out/gate/up/down 常驻 int32）
  -> (Int, Int)          -- ^ (cell, target)
  -> [GF27]
  -> IO [GF27]
layerIntrinsic27C cfg cl (cell, target) x = do
  let addGF27 a b = ST.mkGF27 (gf27Add (ST.gf27ToInt a) (ST.gf27ToInt b))
      heads = scHeads cfg
      dim   = scDim cfg
      gamma = replicate dim ST.gf27One
      qIn   = map (mkTrit . ST.gf27ToInt) x
  -- o = out_proj ⊗ christoffel(q)（q_proj/prototype 已在 CIntLayer 内）
  qOut <- pure (christoffelInt MixGF27 heads (cQProj cl) (cPrototype cl) cell target qIn)
  oOutI <- gf27MatmulCTableVec dim dim (cOutProj cl) (VS.fromList (map fromIntegral qOut))
  let oOut = map (ST.mkGF27 . fromIntegral) (VS.toList oOutI)
  let x1 = gf27RmsNorm gamma (zipWith addGF27 x oOut)
  -- SwiGLU：gate/up（ff×dim）→ 逐分量门控 → down（dim×ff）
  gI <- gf27MatmulCTableVec (scFF cfg) dim (cGateProj cl) (VS.fromList (map (fromIntegral . ST.gf27ToInt) x1))
  uI <- gf27MatmulCTableVec (scFF cfg) dim (cUpProj cl)   (VS.fromList (map (fromIntegral . ST.gf27ToInt) x1))
  let g = map (ST.mkGF27 . fromIntegral) (VS.toList gI)
      u = map (ST.mkGF27 . fromIntegral) (VS.toList uI)
      gated = zipWith (\a b -> ST.mkGF27 (gf27Mul (ST.gf27ToInt a) (ST.gf27ToInt b))) g u
  dI <- gf27MatmulCTableVec dim (scFF cfg) (cDownProj cl) (VS.fromList (map (fromIntegral . ST.gf27ToInt) gated))
  let ffnOut = map (ST.mkGF27 . fromIntegral) (VS.toList dI)
  let x2 = gf27RmsNorm gamma (zipWith addGF27 x1 ffnOut)
  pure x2

-- | **紧凑权重版整链**（'sovereignForwardFullC' 的推荐入口）：
-- 权重已是 'SovereignIntWeightsC'（'loadWeightsSovC' 一次解出常驻），每 token
-- 直接走 60 层 × 4 个 C matmul，**不重建** 'CIntLayer'。内存 ≈5GB（vs 装箱 40GB）。
-- 与 'sovereignForwardFull' 逐 token 逐元素全等（B1/B3 门禁可比）。
sovereignForwardFullCompact
  :: SovereignConfig
  -> SovereignIntWeightsC
  -> WuxingConfig
  -> WuxingLayerW
  -> [Int]
  -> IO [[GF27]]
sovereignForwardFullCompact cfg wc wcfg wl tokenIds = do
  let dim   = scDim cfg
      gamma = replicate dim ST.gf27One
      pairs = [ pr | (_, pr) <- map layerStep12 (take (scDepth cfg) (iterate step12 phase12Init)) ]
      cls   = siwCLayersC wc
      -- 嵌入：查 token 行（激活侧，GF27）
      embedRow tok = siwCEmbed wc !! (tok `mod` length (siwCEmbed wc))
      embedded = [ embedRow t | t <- tokenIds ]
  hidden <- foldM (\hs i pr -> mapM (layerIntrinsic27C cfg (cls !! i) pr) hs)
                  embedded (zip [0 ..] pairs)
  -- ⚠️ 性能剖面（2026-09-17 诊断）：真实 60 层 1.9s/token 里 matmul 只占 ~6%
  -- （240 × 0.49ms ≈ 118ms，benchmarks/cpu/LayerSegProfile.hs S2'' 实证），其余
  -- ~1.8s 是层内激活构造/转换（list↔VS.Vector）·q/christoffel·RmsNorm·五行推理。
  let wxed = [ firstOf4 (wuxingForward wcfg wl h) | h <- hidden ]
      -- bypass：表是 [vocab × dim] 行优先扁平（trit {0,1,2}）→ 查 token 行 → embedGF3
      nTok = length tokenIds
      dim' = scDim cfg
      voc  = scVocab cfg
      bypassRowT tok = map (ST.mkGF27 . fromIntegral)
                       (VS.toList (VS.slice ((tok `mod` voc) * dim') dim' (siwCBypassV wc)))
      bypassed = [ zipWith ST.plusGF27 h (bypassRowT t)
                 | (h, t) <- zip wxed tokenIds ]
      normed = map (gf27RmsNorm gamma) bypassed
      headV = siwCLmHeadV wc
  headLogits <- mapM (\row -> do
                        let xv = VS.fromList (map (fromIntegral . ST.gf27ToInt) row)
                        rv <- gf27MatmulCTableVec (scVocab cfg) dim headV xv
                        pure (map (ST.mkGF27 . fromIntegral) (VS.toList rv)))
                     normed
  pure headLogits
  where
    foldM :: (acc -> Int -> (Int, Int) -> IO acc) -> acc -> [(Int, (Int, Int))] -> IO acc
    foldM _ acc [] = pure acc
    foldM f acc ((i, pr) : rest) = do
      acc' <- f acc i pr
      foldM f acc' rest

-- | **P1 探测用诊断版**：与 'sovereignForwardFullCompact' 同构（headLogits
-- 逐位一致），但额外返回每个 token 的 wuxing 4 步链结构输出
-- @(h, st, chain, oks)@（chain = 每步选择 [[(Int,Int)]]，oks = 可达标记 [Bool]）。
-- 判据：'firstOf4' 被丢弃的 chain/oks 正是探测「wuxing 对历史/Z 值是否敏感」的载体
-- （j-mu64lkji-jp4o）。对拍：headLogits 必须 ≡ 'sovereignForwardFullCompact'。
sovereignForwardFullCompactReport
  :: SovereignConfig
  -> SovereignIntWeightsC
  -> WuxingConfig
  -> WuxingLayerW
  -> [Int]
  -> IO ([[GF27]], [([GF27], T6State, [[(Int, Int)]], [Bool])])
sovereignForwardFullCompactReport cfg wc wcfg wl tokenIds = do
  let dim   = scDim cfg
      gamma = replicate dim ST.gf27One
      pairs = [ pr | (_, pr) <- map layerStep12 (take (scDepth cfg) (iterate step12 phase12Init)) ]
      cls   = siwCLayersC wc
      embedRow tok = siwCEmbed wc !! (tok `mod` length (siwCEmbed wc))
      embedded = [ embedRow t | t <- tokenIds ]
      voc  = scVocab cfg
      bypassRow tok = map (ST.mkGF27 . fromIntegral)
                      (VS.toList (VS.slice ((tok `mod` voc) * dim) dim (siwCBypassV wc)))
      headV = siwCLmHeadV wc
  hidden <- foldM (\hs i pr -> mapM (layerIntrinsic27C cfg (cls !! i) pr) hs)
                  embedded (zip [0 ..] pairs)
  -- 完整 wuxing 结构（不丢弃 chain/oks）
  let reports = [ wuxingForward wcfg wl h | h <- hidden ]
      wxed    = [ firstOf4 r | r <- reports ]
      bypassed = [ zipWith ST.plusGF27 h (bypassRow t) | (h, t) <- zip wxed tokenIds ]
      normed = map (gf27RmsNorm gamma) bypassed
      structs = [ (h, st, ch, os) | (h, st, ch, os) <- reports ]
  headLogits <- mapM (\row -> do
                        let xv = VS.fromList (map (fromIntegral . ST.gf27ToInt) row)
                        rv <- gf27MatmulCTableVec (scVocab cfg) dim headV xv
                        pure (map (ST.mkGF27 . fromIntegral) (VS.toList rv)))
                     normed
  pure (headLogits, structs)
  where
    foldM :: (acc -> Int -> (Int, Int) -> IO acc) -> acc -> [(Int, (Int, Int))] -> IO acc
    foldM _ acc [] = pure acc
    foldM f acc ((i, pr) : rest) = do
      acc' <- f acc i pr
      foldM f acc' rest

-- | **A2 层 hidden 诊断版**：同 'sovereignForwardFullCompactReport'（headLogits/structs
-- 逐位一致），但**额外返回 60 层后、wuxing 前**的层 hidden（'layerIntrinsic27C' fold 的
-- 直接产出）。用途：B1 新因果层要接「真实层 hidden」（变量 = token 的层 hidden），
-- 而 report 返回的 @structs@ 里 @h@ 是 wuxingForward 之后——层 hidden 才是插入
-- 新因果层的位置（j-mu6cjfaj-gbeu 路径 A）。
sovereignForwardFullCompactReportL
  :: SovereignConfig
  -> SovereignIntWeightsC
  -> WuxingConfig
  -> WuxingLayerW
  -> [Int]
  -> IO ([[GF27]], [([GF27], T6State, [[(Int, Int)]], [Bool])], [[GF27]])
sovereignForwardFullCompactReportL cfg wc wcfg wl tokenIds = do
  let dim   = scDim cfg
      gamma = replicate dim ST.gf27One
      pairs = [ pr | (_, pr) <- map layerStep12 (take (scDepth cfg) (iterate step12 phase12Init)) ]
      cls   = siwCLayersC wc
      embedRow tok = siwCEmbed wc !! (tok `mod` length (siwCEmbed wc))
      embedded = [ embedRow t | t <- tokenIds ]
      voc  = scVocab cfg
      bypassRow tok = map (ST.mkGF27 . fromIntegral)
                      (VS.toList (VS.slice ((tok `mod` voc) * dim) dim (siwCBypassV wc)))
      headV = siwCLmHeadV wc
  hidden <- foldM (\hs i pr -> mapM (layerIntrinsic27C cfg (cls !! i) pr) hs)
                  embedded (zip [0 ..] pairs)
  -- 完整 wuxing 结构（不丢弃 chain/oks）
  let reports = [ wuxingForward wcfg wl h | h <- hidden ]
      wxed    = [ firstOf4 r | r <- reports ]
      bypassed = [ zipWith ST.plusGF27 h (bypassRow t) | (h, t) <- zip wxed tokenIds ]
      normed = map (gf27RmsNorm gamma) bypassed
      structs = [ (h, st, ch, os) | (h, st, ch, os) <- reports ]
  headLogits <- mapM (\row -> do
                        let xv = VS.fromList (map (fromIntegral . ST.gf27ToInt) row)
                        rv <- gf27MatmulCTableVec (scVocab cfg) dim headV xv
                        pure (map (ST.mkGF27 . fromIntegral) (VS.toList rv)))
                     normed
  pure (headLogits, structs, hidden)
  where
    foldM :: (acc -> Int -> (Int, Int) -> IO acc) -> acc -> [(Int, (Int, Int))] -> IO acc
    foldM _ acc [] = pure acc
    foldM f acc ((i, pr) : rest) = do
      acc' <- f acc i pr
      foldM f acc' rest

-- | **C 双表常驻指针版整链**（与 'sovereignForwardFull' 逐元素同构，IO 因 FFI）：
-- 权重一次 'cIntLayer' 预转常驻（60 层 ≈ 5GB，远低于装箱版 ~40GB），每 token
-- 每层走 4 个 C matmul（27×27 双表 + OpenMP 行间并行）。lm_head 也走 C。
-- 返回值与 'sovereignForwardFull' 逐 token 逐元素全等（B1/B3 门禁可比）。
sovereignForwardFullC
  :: SovereignConfig
  -> SovereignIntWeights
  -> WuxingConfig
  -> WuxingLayerW
  -> [Int]
  -> IO [[GF27]]
sovereignForwardFullC cfg w wcfg wl tokenIds = do
  let dim   = scDim cfg
      gamma = replicate dim ST.gf27One
      pairs = [ pr | (_, pr) <- map layerStep12 (take (scDepth cfg) (iterate step12 phase12Init)) ]
      layers = siwLayers w
      cs = map cIntLayer layers
      embedded = embed27 cfg w tokenIds
  -- ① 60 层：fold 内每层 IO
  hidden <- foldM (\hs i pr -> mapM (layerIntrinsic27C cfg (cs !! i) pr) hs)
                  embedded (zip [0 ..] pairs)
  -- ② wuxing 推理（Haskell）
  let wxed = [ firstOf4 (wuxingForward wcfg wl h) | h <- hidden ]
  -- ③ bypass → norm → lm_head（C matmul，**逐 token 单独**：激活向量长度 = dim，
  --    不能把多个 token 拼接成超长向量 —— matmul 只取前 cols 列，会丢 token）
  let bypassed = [ zipWith ST.plusGF27 h (map ST.embedGF3 (tableRow (siwContentBypass w) t))
                 | (h, t) <- zip wxed tokenIds ]
      normed = map (gf27RmsNorm gamma) bypassed
      tableRow table tok = take dim (table !! (tok `mod` length table) ++ repeat (mkTrit 0))
      headV = tritMatToV (siwLmHead w)
  headLogits <- mapM (\row -> do
                        let xv = VS.fromList (map (fromIntegral . ST.gf27ToInt) row)
                        rv <- gf27MatmulCTableVec (scVocab cfg) dim headV xv
                        pure (map (ST.mkGF27 . fromIntegral) (VS.toList rv)))
                     normed
  pure headLogits
  where
    foldM :: (acc -> Int -> (Int, Int) -> IO acc) -> acc -> [(Int, (Int, Int))] -> IO acc
    foldM _ acc [] = pure acc
    foldM f acc ((i, pr) : rest) = do
      acc' <- f acc i pr
      foldM f acc' rest

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
-- 加一个 @post :: [[GF27]] -> a@ 后处理（hidden → 最终输出）。
-- 当前两个实例：
--   * 'runStreaming'（'post = id'，保留历史行为：返回各 token 的 hidden）；
--   * 'runStreamingFull'（'post' = 五行推理 → bypass → norm → lm_head，返回词表 logits）。
runStreamingWith
  :: (Int -> IO BS.ByteString)   -- ^ 按 @data/N@ 的序号取字节
  -> SovereignConfig
  -> ([[GF27]] -> IO (Either String a))
  -> [Int]
  -> IO (Either String a)
runStreamingWith fetch cfg post tokenIds = do
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
    [] -> post []
    _  -> do
      -- 每个 token 独立跑 60 层，收集各自 hidden（[token][dim]）。
      -- ⚠️ 原实现只跑第一个 token（(x0:_) -> go 0 x0）—— 对单 token 调用无差别；
      -- 现在支持多 token（「大脑」需要整条序列的 logits），hidden 收集后交给 post。
      results <- mapM (go 0) embedded
      case sequence results of
        Left e        -> pure (Left e)
        Right hiddens -> post hiddens

-- | 'runStreamingWith' 的历史实例：后处理 = 取**第一个** token 的 hidden
-- （等价原实现 `(x0:_) -> go 0 x0`，对单 token 调用行为不变）。
runStreaming
  :: (Int -> IO BS.ByteString)   -- ^ 按 @data/N@ 的序号取字节
  -> SovereignConfig
  -> [Int]
  -> IO (Either String [GF27])
runStreaming fetch cfg tokenIds =
  runStreamingWith fetch cfg (\hs -> pure (Right (case hs of { h : _ -> h; [] -> [] }))) tokenIds

-- | 流式 **完整链路**：60 层 hidden → 五行推理 → bypass → final norm → lm_head，
-- 返回每个 token 的词表 logits（GF(27) ∈ [0,26]，`[token][vocab]`）。
-- 与 'sovereignForwardFull'（整包载入 'SovereignIntWeights'）逐元素同构，
-- 仅权重来源不同：这里按 'data/N' 流式读取（'data/22'=content_bypass、'data/323'=lm_head）。
runStreamingFull
  :: (Int -> IO BS.ByteString)   -- ^ 按 @data/N@ 的序号取字节
  -> SovereignConfig
  -> WuxingConfig
  -> WuxingLayerW
  -> [Int]
  -> IO (Either String [[GF27]])
runStreamingFull fetch cfg wcfg wl tokenIds =
  runStreamingFullWithB1 False fetch cfg wcfg wl tokenIds

-- | B1 窗口层开关版本（stream-trajectory-b1 #1）：True = 60 层 hidden 后先过
--   'b1ApplyWindow'（因果窗口 Y 槽更新）再 wuxing → bypass → norm → lm_head；
--   False = 与 'runStreamingFull' 逐位一致（对拍保证）。
runStreamingFullWithB1
  :: Bool
  -> (Int -> IO BS.ByteString)
  -> SovereignConfig
  -> WuxingConfig
  -> WuxingLayerW
  -> [Int]
  -> IO (Either String [[GF27]])
runStreamingFullWithB1 enableB1 fetch cfg wcfg wl tokenIds = do
  bypassBs <- fetch 22
  headBs   <- fetch 323
  let dim    = scDim cfg
      vocab  = scVocab cfg
      chunk n xs = case xs of
        [] -> []
        _  -> take n xs : chunk n (drop n xs)
      bypassT :: [[Trit]]
      bypassT = map (map mkTrit) (chunk dim (take (vocab * dim) (unpackTritsInt bypassBs (vocab * dim))))
      headT   = map (map mkTrit) (chunk dim (take (vocab * dim) (unpackTritsInt headBs (vocab * dim))))
      tableRow table tok = take dim (table !! (tok `mod` length table) ++ repeat (mkTrit 0))
      post hidden0 = do
        let hidden = if enableB1 then b1ApplyWindow dim hidden0 else hidden0
        let gamma = replicate dim ST.gf27One
            wxed  = [ firstOf4 (wuxingForward wcfg wl h) | h <- hidden ]
            bypassed = [ zipWith ST.plusGF27 h (map ST.embedGF3 (tableRow bypassT t))
                       | (h, t) <- zip wxed tokenIds ]
            normed = map (gf27RmsNorm gamma) bypassed
            logits = map (gf27Matmul headT) normed
        -- 惰性 BF：不过滤 → 必须强制，否则回到 54 GB 陷阱
        evaluated <- evaluate (map (forceVec . map (id :: GF27 -> GF27)) logits)
        pure (Right evaluated)
  -- 骨架复用 hidden 推进；lm_head 表只算一次（不随 token 变）
  _ <- evaluate (forceMat bypassT) >> evaluate (forceMat headT)
  runStreamingWith fetch cfg post tokenIds

-- | 流式完整链路的 .sov 入口（新「大脑」产 logits 路径）。
forwardStreamingFull
  :: FilePath            -- ^ @.sov@ 文件路径
  -> SovereignConfig
  -> WuxingConfig
  -> WuxingLayerW
  -> [Int]
  -> IO (Either String [[GF27]])
forwardStreamingFull sovPath cfg wcfg wl tokenIds =
  forwardStreamingFullB1 False sovPath cfg wcfg wl tokenIds

-- | 'forwardStreamingFull' 的 B1 窗口层开关版本（stream-trajectory-b1 #1）。
forwardStreamingFullB1
  :: Bool               -- ^ 是否启用 B1 因果窗口层
  -> FilePath
  -> SovereignConfig
  -> WuxingConfig
  -> WuxingLayerW
  -> [Int]
  -> IO (Either String [[GF27]])
forwardStreamingFullB1 enableB1 sovPath cfg wcfg wl tokenIds = do
  img <- BS.readFile sovPath
  let idx = indexZip img
  runStreamingFullWithB1 enableB1
    (\i -> case sovLookup idx ("/data/" ++ show i) of
             Just e  -> pure (sovSlice img e)
             Nothing -> pure BS.empty)
    cfg wcfg wl tokenIds

-- | **「大脑」产下一个 token**（B2/B3 最小闭环）：
-- 给定已生成的 token 序列，跑流式完整链路 → 取最后 token 的词表 logits →
-- 'argMaxIdx' 采样（torch.argmax 语义：最大元素首个下标、平局取最小）。
-- 返回 @(nextToken, lastLogits)@ —— logits 留给诊断/约束判定用。
brainStepToken
  :: FilePath            -- ^ @.sov@ 文件路径
  -> SovereignConfig
  -> WuxingConfig
  -> WuxingLayerW
  -> [Int]               -- ^ 已生成的 token 序列
  -> IO (Either String (Int, [GF27]))
brainStepToken sovPath cfg wcfg wl tokens = do
  r <- forwardStreamingFull sovPath cfg wcfg wl tokens
  pure $ case r of
    Left e        -> Left e
    Right []      -> Left "brainStepToken: empty logits"
    Right (l : _) -> Right (argMaxIdx l, l)

-- | 从 @.sov@ 载入**整包权重**（一次解包，全部常驻内存）：
-- token_emb(data/0 → GF27) · content_bypass(data/22) · lm_head(data/323) ·
-- 60 层 × 5 矩阵（data/23+5k .. 27+5k）。返回 'SovereignIntWeights'。
--
-- ⚠️ 性能（2026-09-17）：'forwardStreamingFull' 每 token 重新读 .sov + 每层解包
-- （60 层单 token 实测 ~222s，其中约 200s 是解包）。预载整包到内存后，
-- 'sovereignForwardFull' 每 token 只做**纯计算**（60 层实测 ~18s）。
-- 内存代价：60 层装箱列表峰值约 40 GB（本机 64 GB 可扛；M21 全 60 层已实测通过）。
loadWeightsFromSov
  :: FilePath            -- ^ @.sov@ 文件路径
  -> Int                 -- ^ heads（真实 = 12）
  -> IO (Either String SovereignIntWeights)
loadWeightsFromSov sovPath heads = do
  img <- BS.readFile sovPath
  let idx = indexZip img
      ff  = 4320; dim = 1440; vocab = 1536; depth = 60
      get i = case sovLookup idx ("/data/" ++ show i) of
        Just e  -> Right (sovSlice img e)
        Nothing -> Left ("data/" ++ show i ++ " 不存在")
      chunk :: Int -> [Int] -> [[Int]]
      chunk n xs = case xs of
        [] -> []
        _  -> take n xs : chunk n (drop n xs)
      mT :: Int -> Int -> BS.ByteString -> [[Trit]]
      mT r c bs = map (map mkTrit)
                    (chunk c (take (r * c) (unpackTritsInt bs (r * c))))
      mG :: Int -> Int -> BS.ByteString -> [[GF27]]
      mG r c bs = map (map ST.mkGF27)
                    (chunk c (take (r * c) (unpackTritsInt bs (r * c))))
      proto = map (map (map mkTrit)) (defaultMonopolePrototype heads)
      layerMat k i = get (23 + 5 * k + i)
  -- 60 层 × 5 矩阵逐个解包（一次）
  layers <- mapM (\k -> do
             q  <- pure (layerMat k 0)
             o' <- pure (layerMat k 1)
             g  <- pure (layerMat k 2)
             u  <- pure (layerMat k 3)
             d  <- pure (layerMat k 4)
             case (q, o', g, u, d) of
               (Right qq, Right oo, Right gg, Right uu, Right dd) ->
                 pure (Right (SovereignIntLayer (mT (heads * 6) dim qq) (mT dim dim oo)
                                                (mT ff dim gg) (mT ff dim uu)
                                                (mT dim ff dd) proto))
               _ -> pure (Left "层矩阵读取失败"))
                 [0 .. depth - 1]
  case sequence layers of
    Left e  -> pure (Left e)
    Right ls -> do
      emb <- pure (get 0)
      byp <- pure (get 22)
      hd  <- pure (get 323)
      case (emb, byp, hd) of
        (Right eb, Right bp, Right hh') ->
          pure (Right (SovereignIntWeights
                         (mG vocab dim eb)
                         (mT vocab dim bp)
                         (mT vocab dim hh')
                         ls))
        _ -> pure (Left "emb/bypass/lm_head 读取失败")

-- | **紧凑版整包权重**：从 @.sov@ 直接解到 'SovereignIntWeightsC'（C 双表常驻）
-- —— token_emb(data/0 → GF27) · content_bypass(data/22) · lm_head(data/323) ·
-- 60 层 × 5 矩阵（data/23+5k .. 27+5k），但**全程无装箱 [[Trit]] 矩阵**：
-- out/gate/up/down 直接进 @VS.Vector Int32@（5 trits/byte 解 → int32，≈5GB/60 层），
-- q_proj/prototype 保留 [[Trit]]（小），embed 保留 [[GF27]]（vocab×dim，供查询）。
--
-- ⚠️ 对照 'loadWeightsFromSov'（40GB 装箱列表，> 本机 CommitLimit 32GB）：
-- 本函数是「预载 C 链」的**唯一可行加载路径**，也是 'sovereignForwardFullC'
-- 每 token 不再重建 'cIntLayer' 的基础（一次解，常驻，FFI 只传指针）。
data SovereignIntWeightsC = SovereignIntWeightsC
  { siwCEmbed   :: [[GF27]]          -- ^ [vocab × dim]（激活侧嵌入）
  , siwCBypassV :: VS.Vector Int32   -- ^ [vocab × dim] 扁平（GF3 权重）
  , siwCLmHeadV :: VS.Vector Int32   -- ^ [vocab × dim] 扁平（GF3 权重）
  , siwCLayersC :: [CIntLayer]
  } deriving (Show, Eq)

-- | 从 .sov 解出**紧凑 C 版权重**（一次解包常驻；60 层 ≈ 5GB，远低于装箱版）。
loadWeightsSovC
  :: FilePath            -- ^ @.sov@ 文件路径
  -> Int                 -- ^ heads（真实 = 12）
  -> IO (Either String SovereignIntWeightsC)
loadWeightsSovC sovPath heads = do
  img <- BS.readFile sovPath
  let idx = indexZip img
      ff  = 4320; dim = 1440; vocab = 1536; depth = 60
      get i = case sovLookup idx ("/data/" ++ show i) of
        Just e  -> Right (sovSlice img e)
        Nothing -> Left ("data/" ++ show i ++ " 不存在")
      -- 5 trits/byte 解包：元素 ∈ 0..2 → 直接扁平 int32 向量（无中间 [[Trit]]）
      mT32 :: Int -> Int -> BS.ByteString -> VS.Vector Int32
      mT32 r c bs = VS.fromList (map fromIntegral (take (r * c) (unpackTritsInt bs (r * c))))
      mG :: Int -> Int -> BS.ByteString -> [[GF27]]
      mG r c bs = map (map ST.mkGF27)
                    (chunk c (take (r * c) (unpackTritsInt bs (r * c))))
      chunk :: Int -> [Int] -> [[Int]]
      chunk n xs = case xs of
        [] -> []
        _  -> take n xs : chunk n (drop n xs)
      proto = map (map (map mkTrit)) (defaultMonopolePrototype heads)
      layerMat k i = get (23 + 5 * k + i)
      mT :: Int -> Int -> BS.ByteString -> [[Trit]]   -- q_proj 保留原始 Trit
      mT r c bs = map (map mkTrit) (chunk c (take (r * c) (unpackTritsInt bs (r * c))))
  layers <- mapM (\k -> do
             q  <- pure (layerMat k 0)
             o' <- pure (layerMat k 1)
             g  <- pure (layerMat k 2)
             u  <- pure (layerMat k 3)
             d  <- pure (layerMat k 4)
             case (q, o', g, u, d) of
               (Right qq, Right oo, Right gg, Right uu, Right dd) ->
                 pure (Right (CIntLayer (mT (heads * 6) dim qq) proto
                             (mT32 dim dim oo) (mT32 ff dim gg)
                             (mT32 ff dim uu) (mT32 dim ff dd)))
               _ -> pure (Left "层矩阵读取失败"))
               [0 .. depth - 1]
  case sequence layers of
    Left e -> pure (Left e)
    Right ls -> do
      emb <- pure (get 0)
      byp <- pure (get 22)
      hd  <- pure (get 323)
      case (emb, byp, hd) of
        (Right eb, Right bp, Right hh') ->
          pure (Right (SovereignIntWeightsC
                         (mG vocab dim eb)
                         (mT32 vocab dim bp)
                         (mT32 vocab dim hh')
                         ls))
        _ -> pure (Left "emb/bypass/lm_head 读取失败")

-- | 从 @.sov@ 内抽 wuxing_reasoning 权重（data/1..21），构造 'WuxingLayerW'。
-- 张量名 ↔ data/N（照 data.pkl 出现顺序，见 test/Spec.hs A6/M18）：
--   1 node_proj[1440,1440]  2 attn_q[1,240]  3 attn_k[1,240]  4 out_proj[1440,1440]
--   5..8 step_node.0..3[72,1440]   9..12 step_trit.0..3[216,1440]
--   13..16 step_t6.0..3[24,1440]   17..20 step_conf.0..3[12,1440]  21 fuse[1440,1440]
loadWuxingFromSov
  :: FilePath            -- ^ @.sov@ 文件路径
  -> Int                 -- ^ heads（真实模型 = 12）
  -> Int                 -- ^ steps（真实 wuxing_reasoning = 4）
  -> Int                 -- ^ trit（= 3）
  -> IO (Either String WuxingLayerW)
loadWuxingFromSov sovPath heads steps trit = do
  img <- BS.readFile sovPath
  let idx = indexZip img
      hex = 6
      dim = 1440
      get i = case sovLookup idx ("/data/" ++ show i) of
        Just e  -> Right (sovSlice img e)
        Nothing -> Left ("data/" ++ show i ++ " 不存在")
      chunk :: Int -> [Int] -> [[Int]]
      chunk n xs = case xs of
        [] -> []
        _  -> take n xs : chunk n (drop n xs)
      m :: Int -> Int -> BS.ByteString -> [[Trit]]
      m r c bs = map (map mkTrit)
                   (chunk c (take (r * c) (unpackTritsInt bs (r * c))))
  case sequence [get 1, get 2, get 3, get 4, get 5, get 9, get 13, get 17, get 21] of
    Left e  -> pure (Left e)
    Right [b1, b2, b3, b4, b5, b9, b13, b17, b21] ->
      let nd = dim `div` hex
          hh = dim `div` heads
          wl = WuxingLayerW
            { wlNodeProj = m dim dim b1
            , wlAttnQ    = m 1 nd b2
            , wlAttnK    = m 1 nd b3
            , wlOutProj  = m dim dim b4
            , wlStepNode = replicate steps (m (heads * hex) dim b5)
            , wlStepTrit = replicate steps (m (heads * hex * trit) dim b9)
            , wlStepT6   = replicate steps (m (heads * 2) dim b13)
            , wlStepConf = replicate steps (m heads dim b17)
            , wlFuse     = m dim dim b21
            , wlGInit    = replicate hex (replicate trit (replicate hh (mkTrit 1))) }
      in pure (Right wl)
    Right _ -> pure (Left "loadWuxingFromSov: 非预期 data/N 数量")

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
