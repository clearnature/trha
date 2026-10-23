-- | B1Lm：**闭环验证**——新因果层的 Y 槽更新回读 lm_head。
--
-- 链路（全部复用现有组件，不改 SovereignFull）：
--   ① reportL 取 6 token 层 hidden（wuxing 前）
--   ② b1full 计算 Y 槽更新（prop[Y] ⊕ var_Y 残差）
--   ③ 把 Y 槽更新**替换**进 hidden 的第 2 槽（Y 变量槽）——干预/条件化只改 X/Z 槽，
--      因此 Y 槽替换值 obs/do/cond 三版本不同 ⟹ 差异纯来自 B1 因果层的传播
--   ④ 对替换后的 hidden 走 bypass → RMS norm → lm_head → 该 token 的 logits 分布
--   ⑤ 对比 obs/do/cond 的 logits：系统变化 = 闭环成立（因果层影响模型输出）
module Main (main) where

import Control.Exception (evaluate)
import System.Environment (getArgs)
import Data.List (sortOn)
import qualified Data.Vector.Storable as VS

import Infrastructure.CPU.SovereignFull
  ( loadWeightsSovC, loadWuxingFromSov, sovereignForwardFullCompactReportL
  , SovereignIntWeightsC(..) )
import Infrastructure.CPU.SovereignModel (SovereignConfig(..))
import Infrastructure.CPU.SovereignWuxingLayer ( WuxingConfig(..) )
import Infrastructure.CPU.SovereignTypes (GF27, mkTrit, gf27ToInt, tritToInt, gf27One)
import Infrastructure.CPU.GF3Intrinsic (tritMul)
import Infrastructure.CPU.SovereignGF27 ( gf27RmsNorm )
import Infrastructure.CPU.GF27SIMD (gf27MatmulCTableVec)
import qualified Infrastructure.CPU.SovereignTypes as ST

cfg :: SovereignConfig
cfg = SovereignConfig { scDim = 1440, scDepth = 60, scHeads = 12
                      , scVocab = 1536, scFF = 4320, scEps = 1e-5 }

wcfg :: WuxingConfig
wcfg = WuxingConfig 1440 12 4 6 3

encNode :: [GF27] -> Int
encNode n =
  let es = take 8 n
      sig = foldl (\acc e -> acc * 3 + (gf27ToInt e `mod` 3)) 0 es
      lo = sig `mod` 3
      hi = (sig `div` 3) `mod` 3
      t  = (lo + hi) `mod` 3
  in if t == 0 then 1 else t

-- 与 B1FullProbe 相同的 b1full（Y 槽 index 2）
b1full :: [[GF27]] -> ([[Int]], [Int])
b1full vars = (adj, yUpd)
  where
    quads = map encNode vars
    adj = [ [ tritToInt (tritMul (mkTrit (quads !! i)) (mkTrit (quads !! j))) | j <- [0 .. 5] ]
          | i <- [0 .. 5] ]
    mulE v a = ST.mulGF27 v (ST.embedGF3 (mkTrit a))
    prop =
      [ [ foldl (\acc i -> ST.plusGF27 acc (mulE (vars !! i !! d) (adj !! i !! j)))
                ST.gf27Zero [0 .. 5]
        | d <- [0 .. 1439] ]
      | j <- [0 .. 5] ]
    yIdx = 2
    yProp = prop !! yIdx
    yUpd = [ ST.gf27ToInt (ST.plusGF27 a b) | (a, b) <- zip yProp (vars !! yIdx) ]

-- 替换 Y 槽后走 bypass+norm+lm_head（复刻 report 的 headLogits 段；C 版 lm head）
lmProbe :: SovereignIntWeightsC -> [GF27] -> Int -> Int -> IO [Int]
lmProbe wc hiddenY tok dimV = do
  let bypassRow = map (ST.mkGF27 . fromIntegral)
                  (VS.toList (VS.slice ((tok `mod` 1536) * dimV) dimV (siwCBypassV wc)))
      gamma = replicate dimV gf27One
      normed = gf27RmsNorm gamma (zipWith ST.plusGF27 hiddenY bypassRow)
      headV = siwCLmHeadV wc
      xv = VS.fromList (map (fromIntegral . ST.gf27ToInt) (take dimV (normed ++ repeat ST.gf27Zero)))
  rv <- gf27MatmulCTableVec 1536 dimV headV xv
  pure (map fromIntegral (VS.toList rv))

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  putStrLn "=== B1Lm：因果层 Y 槽更新回读 lm_head（闭环验证）==="
  ew <- loadWeightsSovC sov 12
  wlw <- loadWuxingFromSov sov 12 4 3
  case (ew, wlw) of
    (Left e, _) -> putStrLn ("weights ✗ " ++ e)
    (_, Left e) -> putStrLn ("wuxing ✗ " ++ e)
    (Right wc, Right wl) -> do
      let obsToks  = [1, 2, 3, 4, 5, 6]
          doToks   = [7, 2, 3, 4, 5, 6]
          condToks = [1, 100, 3, 4, 5, 6]
      (_, _, hO) <- sovereignForwardFullCompactReportL cfg wc wcfg wl obsToks
      (_, _, hD) <- sovereignForwardFullCompactReportL cfg wc wcfg wl doToks
      (_, _, hC) <- sovereignForwardFullCompactReportL cfg wc wcfg wl condToks
      let (_, yO) = b1full hO
          (_, yD) = b1full hD
          (_, yC) = b1full hC
          -- Y 槽 index 2：替换成因果层更新（Int → GF27）
          hiddenYO = take 2 hO ++ [map (ST.mkGF27 . fromIntegral) yO] ++ drop 3 hO
          hiddenYD = take 2 hD ++ [map (ST.mkGF27 . fromIntegral) yD] ++ drop 3 hD
          hiddenYC = take 2 hC ++ [map (ST.mkGF27 . fromIntegral) yC] ++ drop 3 hC
      lO <- lmProbe wc (hiddenYO !! 2) 3 1440     -- token 3 = 第 2 槽原 token
      lD <- lmProbe wc (hiddenYD !! 2) 3 1440
      lC <- lmProbe wc (hiddenYC !! 2) 3 1440
      -- 黄金对照 1：原始 Y 槽（未替换）过 lmProbe → 应与真实前向 logits（reportL 的 headLogits）一致
      lRaw <- lmProbe wc (hO !! 2) 3 1440
      (logsO, _, _) <- sovereignForwardFullCompactReportL cfg wc wcfg wl obsToks
      let trueLog = map gf27ToInt (logsO !! 2)   -- 第 2 槽真实 logits
      -- 黄金对照 2：随机替换 Y 槽（确定性伪随机）→ 验证全量变化非因果层特异
      let rnd = zipWith (\i d -> ST.mkGF27 ((i * 7 + d) `mod` 27)) [0 ..] (map gf27ToInt (hO !! 2))
          hiddenRandom = take 2 hO ++ [rnd] ++ drop 3 hO
      lRnd <- lmProbe wc (hiddenRandom !! 2) 3 1440
      let diffL a b = length (filter (/= 0) (zipWith (-) a b))
          top a = take 8 a
          -- GF27 logits 值域 [0,26]；softmax 得分布，取 topK 索引的集体 KL
          softmax xs =
            let mx = fromIntegral (maximum xs) :: Double
                es = map (\x -> exp ((fromIntegral x - mx) / 10.0)) xs  -- 温度 10：值域差 26 压制
                s = sum es
            in map (/ s) es
          topK idxs ps = take 5 (map (\i -> ps !! i) idxs)
          klAux a b = -- top-5 集体 KL（索引取 a 的 top-5）
            let pa = softmax a; pb = softmax b
                idx = map snd (sortOn (\(v, _) -> -v) (zip a [0 ..]))
                ta = take 5 idx
                pv = map (\i -> pa !! i) ta
                qv = map (\i -> pb !! i) ta
            in sum (zipWith (\p q -> if p > 0 then p * log (p / max q 1e-12) else 0) pv qv)
          crit nm x y =
            putStrLn ("  " ++ nm ++ ": 非零=" ++ show (diffL x y) ++ "/1536  L2="
                      ++ show (l2 x y) ++ "  top1变?=" ++ show (top1Diff x y)
                      ++ "  top5KL=" ++ show (klAux x y))
          l2 a b = sqrt (fromIntegral (sum (zipWith (\x y -> (x - y) * (x - y)) a b)) :: Double)
          top1Diff a b =
            let best = head (map snd (sortOn (\(v, _) -> -v) (zip a [0 ..])))
            in best /= head (map snd (sortOn (\(v, _) -> -v) (zip b [0 ..])))
          -- 方向集中度：Δ = a-b 的逐维平方；按降序排，前 10% 维度的平方和占比
          --   结构化（因果层沿少数输出方向变）→ 占比高（>0.3）
          --   弥散（随机替换等权扰动全部输出）→ 占比低（≈0.1）
          concentration a b =
            let ds = sortOn negate (zipWith (\x y -> (x - y) * (x - y)) a b)
                total = sum ds
                k = max 1 (length ds `div` 10)
                topk = sum (take k ds)
            in if total == 0 then 0 else fromIntegral topk / fromIntegral total :: Double
      putStrLn ("  Y槽更新 obs头部=" ++ show (take 8 yO))
      putStrLn ("  Y槽更新 do 头部=" ++ show (take 8 yD))
      putStrLn ("  Y槽更新 cond头部=" ++ show (take 8 yC))
      putStrLn ("  [三判据] obs→干预: 非零=" ++ show (diffL lO lD) ++ "/1536  L2=" ++ show (l2 lO lD)
                ++ "  top1变?=" ++ show (top1Diff lO lD) ++ "  top5KL=" ++ show (klAux lO lD))
      putStrLn ("  [三判据] obs→条件: 非零=" ++ show (diffL lO lC) ++ "/1536  L2=" ++ show (l2 lO lC)
                ++ "  top1变?=" ++ show (top1Diff lO lC) ++ "  top5KL=" ++ show (klAux lO lC))
      putStrLn ("  [三判据] 干预→条件: 非零=" ++ show (diffL lD lC) ++ "/1536  L2=" ++ show (l2 lD lC)
                ++ "  top1变?=" ++ show (top1Diff lD lC) ++ "  top5KL=" ++ show (klAux lD lC))
      putStrLn ("  [对照2·三判据] 随机替换 vs obs: 非零=" ++ show (diffL lO lRnd) ++ "/1536  L2="
                ++ show (l2 lO lRnd) ++ "  top1变?=" ++ show (top1Diff lO lRnd)
                ++ "  top5KL=" ++ show (klAux lO lRnd))
      putStrLn ("  [方向集中度] obs→干预 top10% 占比=" ++ show (concentration lO lD))
      putStrLn ("  [方向集中度] obs→条件 top10% 占比=" ++ show (concentration lO lC))
      putStrLn ("  [方向集中度] 干预→条件 top10% 占比=" ++ show (concentration lD lC))
      putStrLn ("  [方向集中度] 随机替换 top10% 占比=" ++ show (concentration lO lRnd))
      putStrLn ("  [对照1] 未替换Y槽 vs 真实前向logits 差异=" ++ show (diffL lRaw trueLog)
                ++ "/1536 （应≈0：链路正确性）")
      putStrLn ("  [对照2] 随机替换Y槽 vs obs logits 差异=" ++ show (diffL lO lRnd)
                ++ "/1536 （对照全量变化的普遍性）")
      putStrLn ("  logits obs 前8=" ++ show (top lO))
      putStrLn ("  logits do  前8=" ++ show (top lD))
      putStrLn ("  logits cond 前8=" ++ show (top lC))
      _ <- evaluate (length lO + length lD + length lC)
      pure ()