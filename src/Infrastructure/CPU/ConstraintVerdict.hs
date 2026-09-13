-- | 约束判定：把外部（黑盒）模型的输出**投影**到约束原语的输入空间，再运行
-- T⁶ / 因果图 / 五行链，产出一个**可验证的判定**。
--
-- == D-1 的「作用点」（用户 2026-09-13 采纳的定案 D）
--
-- 外部模型是**黑盒** —— 不能改其权重，也不能改其采样。因此约束**不可能**作用于它的
-- 内部计算；它只能作用于"**哪些输出被采纳**"。本模块就是那个作用点：
--
-- > 外部输出  →  视为**候选（draft）**
-- > 候选      →  **投影**成 GF(27) 向量（'projectToGF27'）
-- > 候选      →  过约束（T⁶ 可达性 / 6×6 因果图 / 五行四步链）
-- > 判定      →  **总是**产出（用户裁定①：标注而非拒绝），随响应返回
--
-- 请求侧**不注入**：对黑盒而言注入 prompt/参数只是"建议"，不构成可验收的约束。
--
-- == 与草稿模型的关系（用户裁定③）
--
-- 草稿模型与约束是**同一机制的两面**：草稿输出**必须先过**约束。因此本地三值引擎的
-- 输出与外部模型的输出走**同一条** 'verdictOf' 路径 —— 这正是"两面"的可执行含义。
--
-- == 判据纪律
--
-- 这里验的是**数学/理论正确性**：判定来自 T⁶ 几何（Berry 相位连续性）与 GF(3) 因果图
-- 的可达性，**不是**启发式打分，也不涉及任何性能指标。
module Infrastructure.CPU.ConstraintVerdict
  ( -- * 判定
    ConstraintVerdict (..)
  , VerdictStatus (..)
    -- * 投影桥（黑盒输出 → 约束输入）
  , projectToGF27
    -- * 判定入口
  , verdictOf
  ) where

import Data.Char (ord)

import Infrastructure.CPU.SovereignTypes (GF27, Trit, mkGF27, mkTrit, tritToInt)
import Infrastructure.CPU.SovereignWuxingLayer
  ( WuxingConfig (..)
  , WuxingLayerW (..)
  , causalGraphStep
  , wuxingForward
  )

--------------------------------------------------------------------------------
-- 判定类型
--------------------------------------------------------------------------------

-- | 判定状态。注意**没有**「拒绝」：用户裁定①要求失败时**标注**而非拒绝。
data VerdictStatus
  = VerdictPass   -- ^ 约束通过
  | VerdictWarn   -- ^ 约束未通过 —— **仍返回内容**，仅在响应中标注
  deriving (Show, Eq)

-- | 约束判定的完整结果（随响应返回，供上游决策）。
data ConstraintVerdict = ConstraintVerdict
  { cvStatus :: VerdictStatus
  -- ^ 通过 / 标注
  , cvT6     :: Bool
  -- ^ T⁶ 几何判定 = 五行四步链**每一步**都几何可达
  , cvReach  :: [Bool]
  -- ^ 四步链逐步可达标记（照 'wuxingForward' 的 oks）
  , cvEdges  :: Int
  -- ^ 6×6 因果图的**非零边数**（adj[i][j] ≠ 0 的个数）
  , cvReason :: [Char]
  -- ^ 人类可读依据
  } deriving (Show, Eq)

--------------------------------------------------------------------------------
-- 投影桥：黑盒输出 → 约束输入
--------------------------------------------------------------------------------

-- | 把输出文本**确定性地**映到 GF(27) 向量。
--
-- 这是"作用点"的实质 —— 黑盒输出与约束原语之间必须有这座桥，而且桥必须是**规范的**，
-- 否则判定不可复现。
--
-- 规则（照 'mkTrit' / 'mkGF27' 的值域）：字符序数 @mod 3@ 得一个 trit；每 **3** 个 trit
-- 按 @t0 + 3·t1 + 9·t2@ 合成一个 GF(27) 元素（3³ = 27，正好覆盖 [0,26]）。不足补零。
projectToGF27 :: Int -> [Char] -> [GF27]
projectToGF27 dim cs =
  take dim (go (map (mkTrit . (`mod` 3) . ord) cs) ++ repeat (mkGF27 0))
  where
    go (a : b : c : rest) = mkGF27 (tritToInt a + 3 * tritToInt b + 9 * tritToInt c) : go rest
    go [a, b]             = [ mkGF27 (tritToInt a + 3 * tritToInt b) ]
    go [a]                = [ mkGF27 (tritToInt a) ]
    go []                 = []

--------------------------------------------------------------------------------
-- 规范层：使判定**可复现**的最小确定性权重
--
-- 与 test-cpu 用的同一构造法（元素 = (i*7 + j*13 + seed) mod 3），因此判定可在
-- 任何环境下复算。这里刻意**不**引入随机或外部状态。
--------------------------------------------------------------------------------

dimV, headsV, stepsV, hexV, tritV :: Int
dimV = 24; headsV = 3; stepsV = 2; hexV = 6; tritV = 3

-- | 确定性 trit 矩阵 @[r × c]@，元素 = @(i*7 + j*13 + seed) mod 3@。
w3v :: Int -> Int -> Int -> [[Trit]]
w3v r c sd = [ [ mkTrit ((i * 7 + j * 13 + sd) `mod` 3) | j <- [0 .. c - 1] ]
             | i <- [0 .. r - 1] ]

ndV :: Int
ndV = dimV `div` hexV

verdictCfg :: WuxingConfig
verdictCfg = WuxingConfig dimV headsV stepsV hexV tritV

verdictLayer :: WuxingLayerW
verdictLayer =
  WuxingLayerW
    { wlNodeProj = w3v dimV (hexV * ndV) 1
    , wlAttnQ    = w3v ndV 1 2
    , wlAttnK    = w3v ndV 1 3
    , wlOutProj  = w3v (hexV * ndV) dimV 4
    , wlStepNode = replicate stepsV (w3v dimV (headsV * hexV) 5)
    , wlStepTrit = replicate stepsV (w3v dimV (headsV * hexV * tritV) 6)
    , wlStepT6   = replicate stepsV (w3v dimV (headsV * 2) 7)
    , wlStepConf = replicate stepsV (w3v dimV headsV 8)
    , wlFuse     = w3v (headsV * (dimV `div` headsV)) dimV 9
    , wlGInit    = replicate hexV (replicate tritV (replicate (dimV `div` headsV) (mkTrit 1)))
    }

--------------------------------------------------------------------------------
-- 判定入口
--------------------------------------------------------------------------------

-- | **唯一的判定入口** —— 外部模型输出与草稿（本地三值）输出都走这里，
-- 这就是用户裁定③所说的"草稿模型与约束是同一机制的两面"。
--
-- 判定**总是**产出（裁定①）：不通过时状态为 'VerdictWarn' 并给出依据，
-- 调用方**仍**应返回内容，只是把 'ConstraintVerdict' 附在响应上。
verdictOf :: [Char] -> ConstraintVerdict
verdictOf out =
  let xs            = projectToGF27 dimV out
      (adj, _)      = causalGraphStep verdictCfg verdictLayer xs
      (_, _, _, oks) = wuxingForward verdictCfg verdictLayer xs
      edges         = length [ () | row <- adj, v <- row, tritToInt v /= 0 ]
      t6ok          = and oks
      reached       = length (takeWhile id oks)
  in ConstraintVerdict
       { cvStatus = if t6ok then VerdictPass else VerdictWarn
       , cvT6     = t6ok
       , cvReach  = oks
       , cvEdges  = edges
       , cvReason =
           if t6ok
             then "constraint ok: T6 reachable in all steps, causal edges = " ++ show edges
             else "constraint warn: T6 unreachable at step " ++ show reached
                    ++ "/" ++ show (length oks) ++ ", causal edges = " ++ show edges
       }
