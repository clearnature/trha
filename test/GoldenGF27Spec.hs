{-# LANGUAGE OverloadedStrings #-}

-- | Golden GF27 —— M1 试点：FML 权威表 → 单源 JSON → 内核对拍。
--
-- 数据流（单源）：
--   1. 权威：`/data/work/discrete-mathematics/src/Sovereign/Algebra/FieldTower/GF27.agda`
--      的 `toGF27`（26 子句）与 `fromGF27`（27 子句，零元折到 pow0）。
--   2. 生成器：FML 仓 `scripts/gen-gf27-golden.py` 解析上表 → 写出本文件旁边的
--      `test/golden/gf27.json`，并在 FML 仓写校验编码 pin
--      `GF27Golden.agda`（refl 钉住同一张表；⚠ 校验编码，非数学证明）。
--   3. 本 spec：断言 `GF3Intrinsic` 的 `gf27PowEnc` / `gf27LogTable`
--      与 golden **逐项一致**。
--
-- 被钉住的**约定分歧**（这是它存在的意义，不许再漂）：
--   Agda  `fromGF27 (0,0,0) = pow0`   —— 零元折到单位元
--   trha  `gf27LogTable[0] = -1`      —— 零元哨兵（实现层约定）
--
-- 重新生成：`python3 /data/work/discrete-mathematics/scripts/gen-gf27-golden.py`
module GoldenGF27Spec (goldenGF27Spec) where

import Data.Aeson (Value (..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Scientific (toBoundedInteger)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import System.Directory (doesFileExist)
import Test.Hspec

import Infrastructure.CPU.GF3Intrinsic (gf27LogTable, gf27PowEnc)

-- 定位 golden：cabal 测试的 cwd 可能是包根，也可能在 test/ 下
goldenPath :: IO FilePath
goldenPath = go ["test/golden/gf27.json", "golden/gf27.json"]
  where
    go [] = fail "golden 未找到：test/golden/gf27.json（由 FML scripts/gen-gf27-golden.py 生成）"
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

intField :: String -> KM.KeyMap Value -> IO Int
intField k o = member k (Object o) >>= asInt

encOf :: [Int] -> Int
encOf c = c !! 0 * 1 + c !! 1 * 3 + c !! 2 * 9

-- ---- spec -----------------------------------------------------------------

goldenGF27Spec :: Spec
goldenGF27Spec = describe "Golden GF27 (FML spec freeze, M1)" $ do

  it "pow_enc: trha gf27PowEnc ≡ FML toGF27 表（26 项）" $ do
    g <- loadGolden
    want <- memberArr "pow_enc" g
    length want `shouldBe` 26
    want `shouldBe` VU.toList gf27PowEnc

  it "log27: trha gf27LogTable ≡ FML fromGF27 的逆（27 项，零元 -1 哨兵）" $ do
    g <- loadGolden
    want <- memberArr "log27" g
    length want `shouldBe` 27
    head want `shouldBe` (-1)           -- ★ 约定分歧被本 spec 钉住
    want `shouldBe` VU.toList gf27LogTable

  it "star: enc == t0 + 3*t1 + 9*t2，且 pow_enc[pow] == enc（26 项自洽）" $ do
    g <- loadGolden
    starA <- member "star" g
    star <- arrOf "star" starA
    length star `shouldBe` 26
    pe <- memberArr "pow_enc" g
    mapM_ (\(i, o) -> do
             c  <- memberArr "coords" o
             length c `shouldBe` 3
             p  <- memberInt "pow" o
             p `shouldBe` i
             e  <- memberInt "enc" o
             e `shouldBe` encOf c
             (pe !! i) `shouldBe` e)
          (zip [0 ..] star)

  it "from27: 27 子句；零元约定 (0,0,0) ↦ pow0；其余与 log27 互逆" $ do
    g <- loadGolden
    fA <- member "from27" g
    f27 <- arrOf "from27" fA
    length f27 `shouldBe` 27
    c0 <- memberArr "coords" (head f27)
    c0 `shouldBe` [0, 0, 0]
    p0 <- memberInt "pow" (head f27)
    p0 `shouldBe` 0
    lg <- memberArr "log27" g
    mapM_ (\o -> do
             c <- memberArr "coords" o
             p <- memberInt "pow" o
             if encOf c == 0
               then pure ()               -- 零元：hs 侧哨兵 -1，Agda 侧折到 pow0
               else (lg !! encOf c) `shouldBe` p)
          f27

  it "conventions: 两套零元约定都写进 golden（分歧被显式记录，而非隐藏）" $ do
    g <- loadGolden
    cv <- memberObj "conventions" g
    _ <- member "agda" (Object cv)
    _ <- member "trha" (Object cv)
    pure ()
