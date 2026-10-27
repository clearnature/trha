{-# LANGUAGE OverloadedStrings #-}

-- | 五行推理层的**本源实现**（整数域，无浮点）。
--
-- 参考 @bitnet/wuxing/wuxing_reasoning_layer.py@（159 行）：
--
-- > POLAR, TOROIDAL = 144, 46          # 与 M11 的缠绕常数同源
-- > N_HEX, N_TRIT = 6, 3               # 六节点 × 三值
-- > NUM_HEADS, REASONING_STEPS = 12, 4
-- >
-- > CausalGraphLayer:  nd = dim // N_HEX
-- >   node_proj [dim, N_HEX*nd] / attn_q,k [nd, 1] / out_proj [N_HEX*nd, dim]
-- >   adj = sigmoid(q·kᵀ/√N_HEX)        → N_HEX×N_HEX 可学习邻接
-- > WuxingReasoningLayer:
-- >   step_node ×K [dim, H*N_HEX]       → 选「六节点」之一
-- >   step_trit ×K [dim, H*N_HEX*N_TRIT]→ 再选「三值」之一
-- >   step_t6   ×K [dim, H*2]           → 极向/环向增量，tanh(...)×24
-- >   step_conf ×K [dim, H]              → 置信度 sigmoid
-- >   verifier  : 极向 ∈ [0,144)、环向 ∈ [0,46)、Berry 相位连续（阈值 1.05）
-- >   非法路径 → -1e9（几何不可达）      → 对应 Chern C = −2 保护
-- >   ginit [N_HEX, N_TRIT, hh]         → (节点, trit) 查表得 hh 维片段
-- >   fuse [H*hh, dim]                  → 以 0.1 系数残差回 hidden
--
-- 本源化映射（去掉 sigmoid / tanh / argmax 三处浮点）：
--
-- > sigmoid(邻接)  → GF(3) 乘：adj[i][j] = q_i ⊗ k_j
-- > sigmoid(置信)  → 非零计数门：conf = (非零数 > 阈值)
-- > argmax(选节点) → 整数最大值的下标（三值域上确定）
-- > tanh(·)×24     → Z₁₄₄ × Z₄₆ 上的相位增量（复用 'Phase12' 的十二律时序）
-- > −1e9 不可达    → 'Bool' 标记（False = 几何不可达，永不被选）
--
-- ⚠️ 维度用可配置的小值（真实模型 dim=1440 / heads=12 / steps=4），以便端到端可测。
module Infrastructure.CPU.SovereignWuxingLayer
  ( WuxingConfig(..)
  , WuxingLayerW(..)
  , T6State(..)
  , t6Init
  , fuseCoefInv
  , t6Verify
  , causalGraphStep
  , argMaxIdx
  , wuxingStep
  , wuxingForward
  ) where

import Infrastructure.CPU.GF3Intrinsic (tritMul)
import Infrastructure.CPU.SovereignGF27 (gf27Matmul)
import qualified Infrastructure.CPU.SovereignTypes as ST
import Infrastructure.CPU.SovereignTypes (GF27, Trit, mkTrit, gf27ToInt)
import Infrastructure.CPU.SovereignLossGain (polarWinding, toroidalWinding)
import Infrastructure.CPU.SovereignPhase12 (Phase12(..), phase12Init, step12)

-- | 配置：@scDim@ 对应 dim，@wcHeads@ 对应 NUM_HEADS，@wcSteps@ 对应 REASONING_STEPS，
-- @wcHex@ = N_HEX = 6，@wcTrit@ = N_TRIT = 3。
data WuxingConfig = WuxingConfig
  { wcDim   :: Int     -- ^ dim（真实 1440）
  , wcHeads :: Int     -- ^ NUM_HEADS（12）
  , wcSteps :: Int     -- ^ REASONING_STEPS（4）
  , wcHex   :: Int     -- ^ N_HEX（6）
  , wcTrit  :: Int     -- ^ N_TRIT（3）
  } deriving (Show, Eq)

-- | 一层的权重（全部为 trit / 整数；本源域内运算）。
data WuxingLayerW = WuxingLayerW
  { wlNodeProj :: [[Trit]]       -- ^ [dim, hex*nd]
  , wlAttnQ    :: [[Trit]]       -- ^ [nd, 1]
  , wlAttnK    :: [[Trit]]       -- ^ [nd, 1]
  , wlOutProj  :: [[Trit]]       -- ^ [hex*nd, dim]
  , wlStepNode :: [[[Trit]]]     -- ^ steps × [dim, heads*hex]
  , wlStepTrit :: [[[Trit]]]     -- ^ steps × [dim, heads*hex*trit]
  , wlStepT6   :: [[[Trit]]]     -- ^ steps × [dim, heads*2]
  , wlStepConf :: [[[Trit]]]     -- ^ steps × [dim, heads]
  , wlFuse     :: [[Trit]]       -- ^ [heads*hh, dim]
  , wlGInit    :: [[[Trit]]]     -- ^ [hex][trit][hh]
  } deriving (Show, Eq)

-- | T⁶ 验证器状态：极向 / 环向 / Berry 相位（都是整数，落在各自的缠绕模上）。
data T6State = T6State
  { t6Polar    :: Int   -- ^ mod 'polarWinding'  (144)
  , t6Toroidal :: Int   -- ^ mod 'toroidalWinding' (46)
  , t6Berry    :: Int   -- ^ Berry 相位的定点表示（见 't6Verify'）
  } deriving (Show, Eq)

t6Init :: T6State
t6Init = T6State 0 0 0

-- | 「0.1 系数」在 **GF(27)** 里的本源形式：@10⁻¹ = 23@。
--
-- ⚠️ 注意这**不是**整数环 @Z/27@ 的逆元 —— 那是 19（因 @10 × 19 ≡ 190 ≡ 1 mod 27@）。
-- GF(27) 的元素按**三进制**编码（@n = n₀ + 3n₁ + 9n₂@），乘法是**多项式乘 mod @α³ = α + 2@**，
-- 全程**不做**整数取模。故 10 的域内逆元必须用域乘法求：@gf27Mul 10 23 = 1@（穷举唯一解）。
-- 把 Z/27 的逆元用在这里是**范畴混淆**（域 vs 环，见判据 C2）。
--
-- 用它替代旧的 @\`div\` 10@，从而**不截断**（27 进 → 27 出，且 d ≠ 0 ⇒ 23 ⊗ d ≠ 0）。
-- 见 'wuxingStep' 里 h' 的注释。
fuseCoefInv :: GF27
fuseCoefInv = ST.mkGF27 23

-- | T⁶ 几何验证：极向与环向必须落在各自缠绕内，Berry 相位必须**连续**
-- （对应参考里的 @(b − pb).abs() < 1.05@；这里用整数的相位差阈值）。
t6Verify :: T6State -> Int -> Int -> Int -> Bool
t6Verify st dPolar dToroidal dBerry =
  let np = (t6Polar st + dPolar) `mod` polarWinding
      nt = (t6Toroidal st + dToroidal) `mod` toroidalWinding
      nb = t6Berry st + dBerry
  in np >= 0 && np < polarWinding
     && nt >= 0 && nt < toroidalWinding
     && abs nb < berryThresholdQ     -- 相位连续（定点阈值）
  where berryThresholdQ = 105        -- 1.05 ×100（与参考的 1.05 同尺度）

--------------------------------------------------------------------------------
-- 因果图（本源版）
--------------------------------------------------------------------------------

-- | 取向量首元素（空则 0）—— 避免部分函数。见 'scalarOf'。
-- | 取 GF(27) 向量首元素并**投影回 GF(3)**（取低分量 a）。空则零。
--
-- ⚠️ 这是有意的范畴下降：@q ⊗ k@ 的离散对应只需要 GF(3) 标量。
scalarOf :: [GF27] -> Trit
scalarOf (v : _) = mkTrit (gf27ToInt v `mod` 3)
scalarOf []      = mkTrit 0

-- | @adj[i][j] = q_i ⊗ k_j@ —— sigmoid 的 GF(3) 离散对应。
causalGraphStep :: WuxingConfig -> WuxingLayerW -> [GF27] -> ([[Trit]], [GF27])
causalGraphStep cfg w x = (adj, updated)
  where
    hex = wcHex cfg
    dim = wcDim cfg
    nd  = dim `div` hex                                   -- 对应 nd = dim // N_HEX
    nodeH = gf27Matmul (wlNodeProj w) x                   -- [hex*nd]
    nodes = [ take nd (drop (i * nd) nodeH) | i <- [0 .. hex - 1] ]
    qs = [ scalarOf (gf27Matmul (wlAttnQ w) n) | n <- nodes ]  -- 每个节点一个标量
    ks = [ scalarOf (gf27Matmul (wlAttnK w) n) | n <- nodes ]
    -- 权重（Trit）与激活（GF27）不同范畴，相乘前经 ST.embedGF3 提升。
    mulBy a = ST.mulGF27 (ST.embedGF3 a)
    -- GF(3) 邻接：sigmoid(q·kᵀ/√hex) 的离散对应
    adj = [ [ tritMul (qs !! i) (ks !! j) | j <- [0 .. hex - 1] ] | i <- [0 .. hex - 1] ]
    -- 图传播：prop[j] = Σ_i node[i] ⊗ adj[i][j]，再经 out_proj 与残差
    prop = [ concatMap (\i -> map (mulBy (adj !! i !! j)) (nodes !! i)) [0 .. hex - 1]
           | j <- [0 .. hex - 1] ]
    flat = concat prop
    out  = gf27Matmul (wlOutProj w) (take dim (flat ++ repeat ST.gf27Zero))
    updated = zipWith ST.plusGF27 out (take dim (x ++ repeat ST.gf27Zero))

-- | 整数域上的 argmax 下标（平局取最小下标，确定）。
argMaxIdx :: [GF27] -> Int
argMaxIdx []       = 0
argMaxIdx (v0 : vs) = snd (foldl step (v0, 0) (zip vs [1 ..]))
  where step (best, bi) (v, i) = if gf27ToInt v > gf27ToInt best then (v, i) else (best, bi)

--------------------------------------------------------------------------------
-- 4 步推理链（本源版）
--------------------------------------------------------------------------------

-- | 一步推理：选六节点 → 选三值 → T⁶ 验证 → 查 ginit → 残差融合。
-- 返回（新相位、当前 hidden、本步选中的 (节点, trit) 列表、可达标记）。
wuxingStep
  :: WuxingConfig
  -> WuxingLayerW
  -> Int                 -- ^ 步序号 k
  -> Phase12             -- ^ 十二律相位机（提供极向/环向增量）
  -> T6State
  -> [GF27]
  -> (Phase12, T6State, [GF27], [(Int, Int)], Bool)
wuxingStep cfg w k ph st x =
  let hex  = wcHex cfg
      trit = wcTrit cfg
      heads = wcHeads cfg
      hh   = wcDim cfg `div` heads
      layerAt f = (f w) !! k

      -- 选节点：step_node → [heads*hex]，每个 head 的 hex 个分量取最大
      nk = gf27Matmul (layerAt wlStepNode) x
      nodeIdx = [ argMaxIdx (take hex (drop (h * hex) nk)) | h <- [0 .. heads - 1] ]

      -- 选 trit：step_trit → [heads*hex*trit]
      tk = gf27Matmul (layerAt wlStepTrit) x
      tritIdx = [ argMaxIdx (take trit (drop ((h * hex + nodeIdx !! h) * trit) tk))
                | h <- [0 .. heads - 1] ]

      -- T⁶ 增量：step_t6 → [heads*2]（极向、环向各一）
      t6v = gf27Matmul (layerAt wlStepT6) x
      dPol = sum [ gf27ToInt (t6v !! (h * 2))     | h <- [0 .. heads - 1] ]
      dTor = sum [ gf27ToInt (t6v !! (h * 2 + 1)) | h <- [0 .. heads - 1] ]
      dBer = dPol - dTor
      reachable = t6Verify st dPol dTor dBer
      st' = T6State ((t6Polar st + dPol) `mod` polarWinding)
                    ((t6Toroidal st + dTor) `mod` toroidalWinding)
                    (t6Berry st + dBer)

      -- 置信度门：非零计数 > 阈值（sigmoid 的离散对应）
      cf = gf27Matmul (layerAt wlStepConf) x
      confOk = length (filter (/= ST.gf27Zero) cf) > (heads `div` 2)

      -- 查 ginit[节点][trit] 得 hh 维片段，拼成 heads*hh
      modVec = concat [ take hh ((wlGInit w !! (nodeIdx !! h)) !! (tritIdx !! h))
                      | h <- [0 .. heads - 1] ]

      -- 非法路径（几何不可达或置信度不足）→ 不融合（对应 -1e9 的"不被选中"）
      ok = reachable && confOk
      fused = if ok then gf27Matmul (wlFuse w) (map ST.embedGF3 (take (heads * hh) modVec))
                    else replicate (wcDim cfg) ST.gf27Zero
      -- 0.1 系数：参考实现是 h + 0.1 * fuse(...)（**浮点**标量乘）。
      -- 本源化到 GF(27) 时把"0.1"读作"**除以 10**"，即**乘 10 的域内逆元**（见 'fuseCoefInv'）。
      -- 于是 h' = x ⊕ (fused ⊗ 23)，是**域内乘法**，因而
      --   · **不截断**：27 个输入给 27 个输出（单射）；旧实现用 `div` 10，
      --     gf27ToInt ∈ [0,26] ⇒ 结果只有 {0,1,2}，其中 [1..9] 全被压成 0；
      --   · **可逆**：10 ⊗ (23 ⊗ d) = d；
      --   · **无零因子**：d ≠ 0 ⇒ 23 ⊗ d ≠ 0（GF(27) 是域）。
      -- 这与本模块既有的本源化同构（tanh(·)×24 → 相位增量、−1e9 → Bool、
      -- sigmoid → GF(3) 乘）：去掉浮点，改用**所在代数结构**的运算。
      h' = zipWith ST.plusGF27 x (map (ST.mulGF27 fuseCoefInv) fused)
      ph' = step12 ph
  in (ph', st', h', zip nodeIdx tritIdx, ok)

-- | 端到端：4 步推理链。
wuxingForward :: WuxingConfig -> WuxingLayerW -> [GF27] -> ([GF27], T6State, [[(Int, Int)]], [Bool])
wuxingForward cfg w x0 =
  let (_, st, h, chain, oks) = foldl step (phase12Init, t6Init, x0, [], []) [0 .. wcSteps cfg - 1]
      step (ph, st', h', ch, os) k =
        let (ph1, st1, h1, sel, ok) = wuxingStep cfg w k ph st' h'
        in (ph1, st1, h1, ch ++ [sel], os ++ [ok])
  in (h, st, chain, oks)
