-- | C2 负面用例 6：GF(9) 的元素不能当 GF(27) 用。
--
-- 依据 SovereignTypes.hs 的模块头（范畴表）：
--   GF9   = GF(3²) = GF(3)[α]/(α²+1) 的元素，表示为 (a, b) = a + bα
--   GF27  = GF(3³) 的元素，值域 [0,26]
-- 二者是**不同的扩域**（次数 2 vs 3，元素个数 9 vs 27），不是同一个范畴的两种表示。
--
-- 预期：**编译失败**。
module Main (main) where

import Infrastructure.CPU.SovereignTypes (GF27, mkGF9)

main :: IO ()
main = print (mkGF9 (1, 0) :: GF27)
