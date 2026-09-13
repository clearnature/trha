{-# LANGUAGE ScopedTypeVariables #-}

-- | C2 负面用例 4：全息 π 的**原子**不可做算术。
--
-- 权威（HolographicPi.agda）："全息 π 作为原子配对……禁止约分由类型保证"。
-- 本用例断言：对 'PolarRep' 直接做加法**必须编译失败** —— 若它能编译，说明这个模块
-- 给了原子 @Num@ 实例，"原子性"就守不住了。
--
-- 预期：**编译失败**。
module Main (main) where

import Infrastructure.CPU.HoloPi (PolarRep, polar144)

main :: IO ()
main = print (polar144 + polar144 :: PolarRep)
