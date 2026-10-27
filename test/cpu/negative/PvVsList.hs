-- | C2 负面用例 8：5-trit/字节的打包表示 Pv 不能当 [Int] 用。
--
-- 依据 SovereignPacked.hs：
--   data Pv = Pv ...            -- 5 trit/字节的**打包**表示
--   pvToList :: Pv -> [Int]     -- 唯一的解包出口（显式命名）
-- 打包表示与"元素列表"是两个范畴：前者是存储格式（Word8 位域），后者是语义序列。
-- 若 Pv 能直接当 [Int] 用，解包出口就形同虚设，打包/解包的边界也就守不住了。
--
-- 预期：**编译失败**。
module Main (main) where

import Infrastructure.CPU.SovereignPacked (pvFromTrits)

main :: IO ()
main = print (pvFromTrits [1, 2, 3] :: [Int])
