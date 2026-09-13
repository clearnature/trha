-- | C2 负面用例 9：Z[ζ₁₂] 的元素（Z12）不能当有理数（Q）用。
--
-- 依据 Z12Sys.hs：
--   data Q   = Q Integer Integer      -- 1 维：有理数 p/q
--   data Z12 = Z12 Q Q Q Q            -- 4 维：Z[ζ₁₂] 的元素（dim = φ(12) = 4）
-- 维数不同（1 vs 4），范畴不同。若 Z12 能当 Q 用，等于把分圆整环的元素压成一个
-- 有理数 —— 那正是"约分/降维"这类被类型系统挡住的事。
--
-- 预期：**编译失败**。
module Main (main) where

import Infrastructure.CPU.Z12Sys (Q, z12one)

main :: IO ()
main = print (z12one :: Q)
