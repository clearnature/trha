{-# LANGUAGE OverloadedStrings #-}

-- | GoldenCross —— 跨实现全等对拍（C3 判据）：trha 内核 ⇄ ternary Rust 仿真。
--
-- 动机（裁定②落地后的下一步，2026-11-11）：trha-core 自带的 Sov.GF 链与
-- ../ternary（三进制计算机 Phase 0 的 Rust 仿真）是同一批 FML 事实的两个实现——
-- 平行实现必须由**共享黄金事实**钉住，不能只靠各自的 golden 断言。
--
-- 数据流（单源，与 GoldenGF27Spec 同纪律）：
--   1. 权威：FML `/data/work/discrete-mathematics`
--      （Sovereign/Algebra/FieldTower/{GF9,GF27}.agda，0 postulate）；
--   2. 生成器：ternary 仓 `src/bin/dump_golden.rs`（61 项 golden 测试锚定到 FML）
--      导出 `fpga/evidence/golden/*.csv`；
--   3. 本 spec：消费 vendored 副本（`test/golden/*.csv`，与 ternary 导出
--      **逐字节一致**），对 trha 的 GF(3)/GF(9)/GF(27) 实现**穷举**对拍：
--        gf3_ops.csv  18 行  ⇄ Sov.Types  plusTrit / mulTrit
--        gf9_ops.csv  162 行 ⇄ Sov.Types  plusGF9 / mulGF9
--        gf27_mul.csv 729 行 ⇄ Sov.GF3Intrinsic gf27MulRef / gf27Mul（表版）
--        gf27_pow.csv  26 行 ⇄ Sov.GF3Intrinsic gf27PowEnc（幂表）
--   4. RTL（ternary 仓 gf27.v / tb_gf27.sv）与板上 sweep 消费**同一份**文件。
--
-- 重新生成：`cd ../ternary && cargo run --release --bin dump_golden`
-- 然后复制 `fpga/evidence/golden/*.csv` 到 `test/golden/`（逐字节复制，不许手改）。
module GoldenCrossSpec (goldenCrossSpec) where

import Control.Exception (evaluate)
import Data.List (isPrefixOf)
import qualified Data.Vector.Unboxed as V
import System.Directory (doesFileExist)
import Test.Hspec

import Sov.GF3Intrinsic (gf27Mul, gf27MulRef, gf27PowEnc)
import Sov.Types
  ( GF9, mkGF9, mkTrit, mulGF9, mulTrit, plusGF9, plusTrit )

-- | 定位 vendored 黄金文件（cabal 从仓库根起跑 ⇒ test/golden/...；
-- 单包目录调试 ⇒ golden/...）。与 GoldenGF27Spec 同一策略。
goldenPath :: String -> IO FilePath
goldenPath name = go ["test/golden/" ++ name, "golden/" ++ name]
  where
    go [] = fail ("golden 未找到：" ++ name
                  ++ "（由 ternary dump_golden 生成，逐字节复制到 test/golden/）")
    go (p : ps) = do
      ok <- doesFileExist p
      if ok then pure p else go ps

-- | 读 CSV 为字符串字段行（跳过表头，# 起截断，空行丢弃）。
readCsv :: FilePath -> IO [[String]]
readCsv p = do
  txt <- readFile p
  _ <- evaluate (length txt)
  pure
    [ fields (takeWhile (/= '#') ln)
    | ln <- lines txt
    , not (null ln)
    , not (any (`isPrefixOf` ln) ["op,", "x,y", "k,z"])
    ]
  where
    fields = words . map (\c -> if c == ',' then ' ' else c)

-- | GF(9) 整数编码（a + 3b）⇄ GF9。
gf9Of :: Int -> GF9
gf9Of v = mkGF9 (v `mod` 3, (v `div` 3) `mod` 3)

goldenCrossSpec :: Spec
goldenCrossSpec =
  describe "GoldenCross (trha ⇄ ternary 跨实现全等, C3)" $ do

    it "GF(3)：plusTrit / mulTrit 与 ternary Rust 穷举全等（18/18）" $ do
      rows <- readCsv =<< goldenPath "gf3_ops.csv"
      length rows `shouldBe` 18
      mapM_ check3 rows

    it "GF(9)：plusGF9 / mulGF9 与 ternary Rust 穷举全等（162/162）" $ do
      rows <- readCsv =<< goldenPath "gf9_ops.csv"
      length rows `shouldBe` 162
      mapM_ check9 rows

    it "GF(27)：gf27MulRef / gf27Mul(表版) 与 ternary Rust 穷举全等（729/729）" $ do
      rows <- readCsv =<< goldenPath "gf27_mul.csv"
      length rows `shouldBe` 729
      mapM_ check27 rows

    it "GF(27)：幂表 gf27PowEnc 与 ternary 导出的 α^k 逐项一致（26 项，α¹³ = 2）" $ do
      rows <- readCsv =<< goldenPath "gf27_pow.csv"
      length rows `shouldBe` 26
      mapM_ (\(k, [_ , z]) -> gf27PowEnc V.! k `shouldBe` read z)
            (zip [0 ..] rows)
  where
    check3 [op, a, b, y] = do
      let ta = mkTrit (read a)
          tb = mkTrit (read b)
          ty = mkTrit (read y)
      if op == "add"
        then plusTrit ta tb `shouldBe` ty
        else mulTrit ta tb `shouldBe` ty
    check3 other = error ("gf3_ops.csv 行格式错误: " ++ show other)

    check9 [op, x, y, z] = do
      let ex = gf9Of (read x)
          ey = gf9Of (read y)
          ez = gf9Of (read z)
      if op == "add"
        then plusGF9 ex ey `shouldBe` ez
        else mulGF9 ex ey `shouldBe` ez
    check9 other = error ("gf9_ops.csv 行格式错误: " ++ show other)

    -- 参考实现（多项式展开）与生产实现（查表 + 循环）都必须逐行命中黄金值。
    check27 [x, y, z] = do
      let ix = read x
          iy = read y
          iz = read z
      gf27MulRef ix iy `shouldBe` iz
      gf27Mul ix iy `shouldBe` iz
    check27 other = error ("gf27_mul.csv 行格式错误: " ++ show other)
