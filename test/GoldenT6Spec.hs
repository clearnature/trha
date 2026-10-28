{-# LANGUAGE OverloadedStrings #-}

-- | Golden T⁶ —— M3 扩展：T⁶ 144×46 golden 对拍。
--
-- 数据流（单源）：FML `src/Sovereign/Base/Invariants.agda` 常量
--   （POLAR_WINDING = 144 / TOROIDAL_WINDING = 46）
--   → `scripts/gen-t6-golden.py` → `test/golden/t6.json`
--   → 本 spec 断言 `Sov.Math.Topology.T6` 与 golden 一致。
--
-- 对拍面：
--   * 常量 144 / 46 / 6624（NSE.agda §0 公理3：TOTAL = 6624，grid-verify = refl）；
--   * `t6Index` 规范域全表 6624 项（p 主序约定）；
--   * 扩展域闭包采样 64 项（负/越界输入的 floor-mod 语义——C 截断 `%` 与
--     Haskell/Python floor `%` 在此分叉，采样即钉此处）；
--   * Christoffel 平行移动 9 项（σ ↦ (σ+1+dir) mod 3）；
--   * 驻波节点 12 项（tone % 3 == 0；数据在案，trha 侧暂无实现——供后续接线）。
--
-- 为什么 golden 化：6624 格点是消费路径上最大的 Agda 锚定对象
-- （NSE.agda §0 公理3 + Invariants.agda 宪法级常量）；abi.md 已有三语言
-- 一致 + Python 独立复算的声明，本 spec 把声明升级为常驻机械门。
module GoldenT6Spec (goldenT6Spec) where

import Data.Aeson (Value (..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.List (sort)
import Data.Scientific (toBoundedInteger)
import qualified Data.Vector as V
import System.Directory (doesFileExist)
import Test.Hspec

import Sov.Math.Topology.T6 (t6Polar, t6Toroidal, t6Total, t6Index, christoffelTransport)
import Sov.Math.Trit (Trit (..))

-- 定位 golden：cabal 测试的 cwd 可能是包根，也可能在 test/ 下
goldenPath :: IO FilePath
goldenPath = go ["test/golden/t6.json", "golden/t6.json"]
  where
    go [] = fail "golden 未找到：test/golden/t6.json（由 FML scripts/gen-t6-golden.py 生成）"
    go (p : ps) = do
      e <- doesFileExist p
      if e then pure p else go ps

loadGolden :: IO Value
loadGolden = do
  p <- goldenPath
  bs <- BS.readFile p
  case A.eitherDecodeStrict' bs of
    Left e  -> fail ("golden JSON 解析失败: " ++ e)
    Right v -> pure v

-- ---- 取值辅助（全部 IO 化，报错带字段名） ---------------------------------

objOf :: String -> Value -> IO (KM.KeyMap Value)
objOf _ (Object o) = pure o
objOf what _       = fail ("golden: " ++ what ++ " 不是对象")

member :: String -> Value -> IO Value
member k (Object o) = case KM.lookup (Key.fromString k) o of
  Just x  -> pure x
  Nothing -> fail ("golden 缺字段: " ++ k)
member k v = fail ("golden: " ++ k ++ " 不是对象")

memberObj :: String -> Value -> IO (KM.KeyMap Value)
memberObj k v = member k v >>= objOf k

asInt :: Value -> IO Int
asInt (Number n) = maybe (fail ("非整数: " ++ show n)) pure (toBoundedInteger n)
asInt other      = fail ("非数字: " ++ show other)

intsIn :: String -> Value -> IO [Int]
intsIn what (Array a) = mapM asInt (V.toList a)
intsIn what _         = fail ("golden: " ++ what ++ " 不是数组")

memberArr :: String -> Value -> IO [Int]
memberArr k v = member k v >>= intsIn k

memberInt :: String -> Value -> IO Int
memberInt k v = member k v >>= asInt

arrOf :: String -> Value -> IO [Value]
arrOf what (Array a) = pure (V.toList a)
arrOf what _         = fail ("golden: " ++ what ++ " 不是数组")

boolsIn :: String -> Value -> IO [Bool]
boolsIn what (Array a) = mapM asBool (V.toList a)
  where asBool (Bool b) = pure b
        asBool other    = fail ("golden: " ++ what ++ " 含非布尔项")
boolsIn what _         = fail ("golden: " ++ what ++ " 不是数组")

intField :: String -> KM.KeyMap Value -> IO Int
intField k o = member k (Object o) >>= asInt

-- ---- spec -----------------------------------------------------------------

goldenT6Spec :: Spec
goldenT6Spec = describe "Golden T6 (144×46, M3)" $ do

  it "constants: polar=144 / toroidal=46 / total=6624 ≡ FML Invariants.agda" $ do
    g <- loadGolden
    c <- memberObj "constants" g
    p <- intField "polar" c
    t <- intField "toroidal" c
    n <- intField "total" c
    p `shouldBe` t6Polar
    t `shouldBe` t6Toroidal
    n `shouldBe` t6Total
    t6Total `shouldBe` 6624

  it "index_canonical: 6624 项 p 主序全表（t6Index 逐项一致）" $ do
    g <- loadGolden
    want <- memberArr "index_canonical" g
    length want `shouldBe` 6624
    -- p ∈ 0..143, t ∈ 0..45：t6Index p t ≡ table[p·46 + t]（p 主序约定）
    mapM_
      (\(i, want_i) ->
         let p = i `div` 46
             t = i `mod` 46
          in t6Index p t `shouldBe` want_i)
      (zip [0 ..] want)

  it "closure: 负/越界输入 floor-mod 封闭（64 采样，含 ±一个整周期）" $ do
    g <- loadGolden
    csA <- member "index_closure_samples" g
    cs <- arrOf "index_closure_samples" csA
    length cs `shouldBe` 64
    mapM_
      (\o -> do
         triple <- intsIn "closure 采样" o
         case triple of
           [p, t, idx] -> t6Index p t `shouldBe` idx
           _           -> fail "closure 采样应为 [p, t, idx] 三元")
      cs
    -- 关键边界显式钉住：(-144,-46) ↦ 0；(144,0) ≡ (0,0) ↦ 0；287/91 ≡ 143/45 ↦ 6623
    t6Index (-144) (-46) `shouldBe` 0
    t6Index 144 0 `shouldBe` 0
    t6Index 287 91 `shouldBe` 6623

  it "christoffel: 9 项 (σ+1+dir) mod 3" $ do
    g <- loadGolden
    want <- memberArr "christoffel" g
    length want `shouldBe` 9
    let tt = [T0, T1, T2]
    mapM_
      (\(s, d) -> do
         let want_i = want !! (s * 3 + d)
         christoffelTransport (tt !! s) (tt !! d) `shouldBe` tt !! want_i)
      [(s, d) | s <- [0 .. 2], d <- [0 .. 2]]

  it "standing_12: 驻波节点 = tone%3==0（十二律域；数据在案供后续接线）" $ do
    g <- loadGolden
    stA <- member "standing_12" g
    st <- boolsIn "standing_12" stA
    length st `shouldBe` 12
    mapM_ (\(i, b) -> b `shouldBe` (i `mod` 3 == 0)) (zip [0 .. 11] st)
    -- 黄金子集（专利 cpp 注释口径）：tone ∈ {0,3,6,9} 为驻波节点
    sort [i | (i, True) <- zip [0 .. 11] st] `shouldBe` [0, 3, 6, 9]
