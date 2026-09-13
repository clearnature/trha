{-# LANGUAGE ScopedTypeVariables #-}

-- | C2 负面用例 2：Z3r 是**环**（Z/3^r），GF27 是**域** —— 范畴不同，不可互换。
--
-- 预期：**编译失败**。这是"环 ≠ 域"这一数学区分在类型层面的强制。
module Main (main) where

import Infrastructure.CPU.SovereignTypes (GF27, mkZ3r)

main :: IO ()
main = print (mkZ3r 1 :: GF27)
