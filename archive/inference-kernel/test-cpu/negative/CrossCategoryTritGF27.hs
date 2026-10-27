{-# LANGUAGE ScopedTypeVariables #-}

-- | C2 负面用例 1：Trit 与 GF27 是不同范畴，不可互换。
--
-- 预期：**编译失败**（GHC 应报类型不匹配）。若这个文件能编译，说明范畴隔离失效。
module Main (main) where

import Infrastructure.CPU.SovereignTypes (GF27, mkTrit)

main :: IO ()
main = print (mkTrit 1 :: GF27)
