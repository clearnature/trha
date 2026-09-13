-- | C2 负面用例 7：谐波指数（Harmonic）不能当域元素（GF27）用。
--
-- 依据 SovereignTypes.hs 的模块头（范畴表）原文：
--   Harmonic  谐波指数（相位周次），**不是元素值**   值域 ℕ
-- 也就是说 Harmonic 是"第几周"的**计数**，不是域里可运算的元素；把它当 GF27 用
-- 会让"相位周次"和"域元素"两个范畴混同。
--
-- 预期：**编译失败**。
module Main (main) where

import Infrastructure.CPU.SovereignTypes (GF27, mkHarmonic)

main :: IO ()
main = print (mkHarmonic 1 :: GF27)
