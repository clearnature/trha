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
-- > 判定      →  **总是**产出，随响应返回
--
-- 请求侧**不注入**：对黑盒而言注入 prompt/参数只是"建议"，不构成可验收的约束。
--
-- == 裁定②（2026-11-11）：判定是**三值**的，二值布尔废止
--
-- 旧裁定①「标注而非拒绝」（pass/warn 两态）被本裁定**取代**。理由：现有智能体的
-- 底层是 0/1 训练出来的，其输出天然非黑即白；内核若也用二值判定，就只剩橡皮图章。
-- 判定值域必须落在内核原生的**三态系数**（GF(3) / 'Trit'）上：
--
-- > 'VerdictPass'   ↔ T1（系数 1）  采纳  —— 入模型可见历史（AssistantMessage）
-- > 'VerdictHold'   ↔ T0（系数 0）  保留  —— 降级为草稿：内容仍随响应返回、仍入日志，
-- >                                      但 constraint 投影明确记为 hold 待复核
-- > 'VerdictReject' ↔ T2（系数 2）  否决  —— **不采纳**：事件记 RejectedAssistant，
-- >                                      不进模型可见历史（审计留痕在事件日志本身）
--
-- 三值归纳（'verdictFromReach'）：逐步可达性全 T1 → pass；全 T2 → reject；
-- 有可达有不可达（混合）→ hold。这与「判定层纪律：三值 Cmp，不是布尔折叠」一致。
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
module Sov.ConstraintVerdict
  ( -- * 判定
    ConstraintVerdict (..)
  , VerdictStatus (..)
  , verdictFromReach
  , verdictTrit
  , reachTrit
    -- * 投影桥（黑盒输出 → 约束输入）
  , projectToGF27
    -- * 判定入口
  , verdictOf
  , verdictOfWithState
  , T6State (..)
  ) where

import Data.Char (ord)

import Sov.Types (GF27, Trit, mkGF27, mkTrit, tritToInt)
import Sov.WuxingLayer
  ( T6State (..)
  , WuxingConfig (..)
  , WuxingLayerW (..)
  , causalGraphStep
  , wuxingForward
  )

--------------------------------------------------------------------------------
-- 判定类型
--------------------------------------------------------------------------------

-- | 判定状态：**三值**（裁定② 2026-11-11），与 GF(3) 的 'Trit' 同构
-- （'verdictTrit' 给出对应）。判定词汇表里没有二值布尔的位置。
data VerdictStatus
  = VerdictPass   -- ^ ↔ T1（系数 1）：约束通过，采纳
  | VerdictHold   -- ^ ↔ T0（系数 0）：约束未通过 —— 内容仍返回，标注保留待复核
  | VerdictReject -- ^ ↔ T2（系数 2）：约束否决 —— **不采纳**，不进模型可见历史
  deriving (Show, Eq)

-- | 判定状态在 GF(3) 上的像：pass ↔ T1，hold ↔ T0，reject ↔ T2。
-- 判定值域带相位（FML 纪律：判决/状态的值域必须落三态系数，不落 0/1）。
verdictTrit :: VerdictStatus -> Trit
verdictTrit VerdictPass   = mkTrit 1
verdictTrit VerdictHold   = mkTrit 0
verdictTrit VerdictReject = mkTrit 2

-- | 三值归纳：由逐步可达性（T1=可达 / T2=不可达）归纳出判定。
-- 全 T1 → pass；全 T2 → reject；混合 → hold。空输入按不可达处置（无据可依即否决）。
verdictFromReach :: [Trit] -> VerdictStatus
verdictFromReach ts
  | null ts         = VerdictReject
  | all (== t1) ts  = VerdictPass
  | all (== t2) ts  = VerdictReject
  | otherwise       = VerdictHold
  where
    t1 = mkTrit 1
    t2 = mkTrit 2

-- | 逐步可达性聚合为总体 T⁶ 几何三值标记：全 T1 → T1，全 T2 → T2，混合 → T0。
-- 不变量：@verdictTrit (verdictFromReach ts) == reachTrit ts@。
reachTrit :: [Trit] -> Trit
reachTrit ts
  | null ts         = mkTrit 2
  | all (== mkTrit 1) ts = mkTrit 1
  | all (== mkTrit 2) ts = mkTrit 2
  | otherwise            = mkTrit 0

-- | 约束判定的完整结果（随响应返回，供上游决策）。
data ConstraintVerdict = ConstraintVerdict
  { cvStatus :: VerdictStatus
  -- ^ 三值判定：采纳 / 保留 / 否决（裁定②）
  , cvT6     :: Trit
  -- ^ T⁶ 几何判定（三值）：T1 = 五行四步链每一步都几何可达，
  -- T2 = 全部不可达，T0 = 混合（部分可达）
  , cvReach  :: [Trit]
  -- ^ 四步链逐步可达标记（T1 可达 / T2 不可达）
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
-- 判定**总是**产出（裁定②）：三值 —— pass 采纳 / hold 保留标注 / reject 否决
-- （reject 的采纳语义见本模块头注释与 'verdictFromReach'）。
verdictOf :: [Char] -> ConstraintVerdict
verdictOf out =
  let xs            = projectToGF27 dimV out
      (adj, _)      = causalGraphStep verdictCfg verdictLayer xs
      (_, _, _, oks) = wuxingForward verdictCfg verdictLayer xs
      edges         = length [ () | row <- adj, v <- row, tritToInt v /= 0 ]
      reach         = map (\ok -> if ok then mkTrit 1 else mkTrit 2) oks
      reached       = length (takeWhile (== mkTrit 1) reach)
      steps         = length reach
  in ConstraintVerdict
       { cvStatus = verdictFromReach reach
       , cvT6     = reachTrit reach
       , cvReach  = reach
       , cvEdges  = edges
       , cvReason = case verdictFromReach reach of
           VerdictPass   -> "constraint pass: T6 reachable in all "
                            ++ show steps ++ " steps, causal edges = " ++ show edges
           VerdictHold   -> "constraint hold: T6 reachable at step " ++ show reached
                            ++ "/" ++ show steps ++ ", causal edges = " ++ show edges
                            ++ " (downgraded to draft, review pending)"
           VerdictReject -> "constraint reject: T6 unreachable at step " ++ show reached
                            ++ "/" ++ show steps ++ ", causal edges = " ++ show edges
                            ++ " (not adopted; excluded from model-visible history)"
       }

-- | 与 'verdictOf' 相同，但**同时返回末态推理状态** 'T6State'。
--
-- 存在的理由（D-3）：'wuxingForward' 的返回值里本来就带终态 @T6State@（逐步可达性
-- 标记与末态都在其返回形状里），只是 'verdictOf' 为保持判定结果精简而
-- 用 @_@ 丢弃了它。推理内核的**状态**要被上浮到内核会话（作为 @Session.projections@
-- 的投影），故在此把它一并交出来 —— 判定字段自裁定②起为三值（'cvStatus' / 'cvT6' /
-- 'cvReach' 均落在 'Trit' 值域）。
--
-- 分层：返回的是 CPU 层的 'T6State'；把它装箱进 @Dynamic@ 由调用方（API.Server）负责，
-- @Core@ 侧只经 'Core.Session.Manager.setProjection' 碰 @Dynamic@，不反向依赖本层。
verdictOfWithState :: [Char] -> (ConstraintVerdict, T6State)
verdictOfWithState out =
  let xs               = projectToGF27 dimV out
      (adj, _)         = causalGraphStep verdictCfg verdictLayer xs
      (_, st, _, oks)  = wuxingForward verdictCfg verdictLayer xs
      edges            = length [ () | row <- adj, v <- row, tritToInt v /= 0 ]
      reach            = map (\ok -> if ok then mkTrit 1 else mkTrit 2) oks
      reached          = length (takeWhile (== mkTrit 1) reach)
      steps            = length reach
  in ( ConstraintVerdict
         { cvStatus = verdictFromReach reach
         , cvT6     = reachTrit reach
         , cvReach  = reach
         , cvEdges  = edges
         , cvReason = case verdictFromReach reach of
             VerdictPass   -> "constraint pass: T6 reachable in all "
                              ++ show steps ++ " steps, causal edges = " ++ show edges
             VerdictHold   -> "constraint hold: T6 reachable at step " ++ show reached
                              ++ "/" ++ show steps ++ ", causal edges = " ++ show edges
                              ++ " (downgraded to draft, review pending)"
             VerdictReject -> "constraint reject: T6 unreachable at step " ++ show reached
                              ++ "/" ++ show steps ++ ", causal edges = " ++ show edges
                              ++ " (not adopted; excluded from model-visible history)"
         }
     , st )
