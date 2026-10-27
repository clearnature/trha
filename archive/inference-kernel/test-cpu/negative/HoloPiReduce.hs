{-# LANGUAGE ScopedTypeVariables #-}

-- | C2 负面用例 5：不能把全息 π 的原子对**拆成两个 Int 再求商**。
--
-- 这条比用例 4 更接近"约分"：真正的危险是有人写
--     let r = polarRepValue p `div` toroidalRepValue t
-- 把 144/46 约成 72/23 或 3，从而绕开"原子对"的约束。
--
-- 本用例断言：**原子对没有可用的除法出口** —— 对 'HoloPi' 直接使用 '/' **必须编译失败**。
--
-- 预期：**编译失败**。
module Main (main) where

import Infrastructure.CPU.HoloPi (holoPi)

main :: IO ()
main = print (holoPi / holoPi)
