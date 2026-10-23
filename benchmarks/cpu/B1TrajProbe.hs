-- | B1Traj：轨迹判据预研（不改主链）。
--
-- 问题（j-mu6dky95 等）：B1Lm 的单步 logits 判据对「因果 vs 随机替换」无区分力。
-- stream-trajectory-b1 提议用轨迹（多步发散）而非单步。本探针先模拟轨迹：
--   窗口 = 6 token 层 hidden → B1 因果层 → Y 槽更新 → 该槽过 lm_head 得 logits
--       → argmax 采样下一 token → 滑窗继续（模拟多步生成）
--   对照 = 同样流程但 Y 槽用**随机替换**（非因果传播）
-- 判据：因果轨迹 vs 随机轨迹的 logits L2 累积距离 / DTW 形态差异。
-- 若轨迹判据区分因果>随机 → 换协议可行；无区分 → 证伪轨迹路线。
module Main (main) where

import Control.Exception (evaluate)
import System.Environment (getArgs)
import qualified Data.Vector.Storable as VS
import Data.List (sortOn)

import Infrastructure.CPU.SovereignFull
  ( loadWeightsSovC, loadWuxingFromSov, sovereignForwardFullCompactReportL
  , SovereignIntWeightsC(..) )
import Infrastructure.CPU.SovereignModel (SovereignConfig(..))
import Infrastructure.CPU.SovereignWuxingLayer ( WuxingConfig(..), WuxingLayerW )
import Infrastructure.CPU.SovereignTypes (GF27, mkTrit, gf27ToInt, tritToInt, gf27One)
import Infrastructure.CPU.GF3Intrinsic (tritMul)
import Infrastructure.CPU.SovereignGF27 (gf27RmsNorm)
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
      lo = sig `mod` 3; hi = (sig `div` 3) `mod` 3; t = (lo + hi) `mod` 3
  in if t == 0 then 1 else t

-- B1 Y 槽更新（prop[Y] ⊕ var_Y，Y 槽=index2）
b1Y :: [[GF27]] -> [Int]
b1Y vars = yUpd
  where
    qs = map encNode vars
    adj = [ [ tritToInt (tritMul (mkTrit (qs !! i)) (mkTrit (qs !! j))) | j <- [0 .. 5] ]
          | i <- [0 .. 5] ]
    mulE v a = ST.mulGF27 v (ST.embedGF3 (mkTrit a))
    prop = [ [ foldl (\acc i -> ST.plusGF27 acc (mulE (vars !! i !! d) (adj !! i !! 2)))
                    ST.gf27Zero [0 .. 5]
            | d <- [0 .. 1439] ] ]
    yProp = head prop
    yUpd = [ ST.gf27ToInt (ST.plusGF27 a b) | (a, b) <- zip yProp (vars !! 2) ]

-- 窗口传播一步：给定 6 个 token 的层 hidden → 更新 Y 槽 → lm_head → logits
stepLm :: SovereignIntWeightsC -> [GF27] -> Int -> Int -> IO [Int]
stepLm wc hiddenY tok dimV = do
  let bypassRow = map (ST.mkGF27 . fromIntegral)
                  (VS.toList (VS.slice ((tok `mod` 1536) * dimV) dimV (siwCBypassV wc)))
      gamma = replicate dimV gf27One
      normed = gf27RmsNorm gamma (zipWith ST.plusGF27 hiddenY bypassRow)
      headV = siwCLmHeadV wc
      xv = VS.fromList (map (fromIntegral . ST.gf27ToInt) (take dimV (normed ++ repeat ST.gf27Zero)))
  rv <- gf27MatmulCTableVec 1536 dimV headV xv
  pure (map fromIntegral (VS.toList rv))

argmax :: [Int] -> Int
argmax xs = snd (maximum (zip xs [0 ..]))

main :: IO ()
main = do
  args <- getArgs
  let sov = case args of (a : _) -> a; [] -> "/home/yanli/work/trha/models/20260721-033421_step31000.sov"
  putStrLn "=== B1Traj：轨迹判据预研（不·该主链）==="
  ew <- loadWeightsSovC sov 12
  wlw <- loadWuxingFromSov sov 12 4 3
  case (ew, wlw) of
    (Left e, _) -> putStrLn ("weights ✗ " ++ e)
    (_, Left e) -> putStrLn ("wuxing ✗ " ++ e)
    (Right wc, Right wl) -> do
      let seedToks = [1, 2, 3, 4, 5, 6]
      (_, _, h0) <- sovereignForwardFullCompactReportL cfg wc wcfg wl seedToks
      -- 后续 token 池（供滑窗/采样）
      let pool = [1 .. 30 :: Int]
      -- 轨迹 A（因果）：每步用 B1 Y 槽更新替换槽2 → lm_head → argmax → 滑窗
      let steps = 8 :: Int
      -- 实现两轨迹（因果 vs 随机替换）的累积 L2
      trajC <- goCaus wc wcfg wl h0 pool steps
      trajR <- goRnd wc wcfg wl h0 pool steps
      let l2 a b = sqrt (fromIntegral (sum (zipWith (\x y -> (x - y) * (x - y)) a b)) :: Double)
          trajL2 = sum [ l2 l1 l2v | (l1, l2v) <- zip trajC trajR ]
          selfC = sum [ l2 l1 l2v | (l1, l2v) <- zip (drop 1 trajC) trajC ]
          selfR = sum [ l2 l1 l2v | (l1, l2v) <- zip (drop 1 trajR) trajR ]
      putStrLn ("  因果轨迹内部 L2=" ++ show (round selfC :: Int))
      putStrLn ("  随机轨迹内部 L2=" ++ show (round selfR :: Int))
      putStrLn ("  因果vs随机 轨迹累积 L2=" ++ show (round trajL2 :: Int))
      putStrLn ("  判据（累积L2 >> 内部L2 → 轨迹发散可区分）："
                ++ show (trajL2 > max selfC selfR))
      evaluate (length trajC + length trajR)
      pure ()

goCaus :: SovereignIntWeightsC -> WuxingConfig -> WuxingLayerW
       -> [[GF27]] -> [Int] -> Int -> IO [[Int]]
goCaus wc wcfg wl h0 pool steps = go h0 pool steps []
  where
    go h p 0 acc = pure (reverse acc)
    go h p n acc = do
      let y = b1Y h                       -- 因果 Y 槽更新
          hY = take 2 h ++ [map (ST.mkGF27 . fromIntegral) y] ++ drop 3 h
      l <- stepLm wc (hY !! 2) (p !! 2) 1440
      let nxt = argmax l
          newPool = drop 1 (p ++ [nxt `mod` 1536])
          h' = drop 1 h ++ [h !! 0]       -- 滑窗（简化：保留原窗口，勿深究）
      go h' newPool (n - 1) (l : acc)

goRnd :: SovereignIntWeightsC -> WuxingConfig -> WuxingLayerW
      -> [[GF27]] -> [Int] -> Int -> IO [[Int]]
goRnd wc wcfg wl h0 pool steps = go h0 pool steps []
  where
    go h p 0 acc = pure (reverse acc)
    go h p n acc = do
      let yRnd = zipWith (\i d -> (i * 7 + d) `mod` 27) [0 :: Int ..] (map gf27ToInt (h !! 2))
          hY = take 2 h ++ [map (ST.mkGF27 . fromIntegral) yRnd] ++ drop 3 h
      l <- stepLm wc (hY !! 2) (p !! 2) 1440
      let nxt = argmax l
          newPool = drop 1 (p ++ [nxt `mod` 1536])
          h' = drop 1 h ++ [h !! 0]
      go h' newPool (n - 1) (l : acc)
