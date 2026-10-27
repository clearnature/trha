-- | FltVerdictProbe：真实数学证明文本过 trha 验证层（verdictOf）——实弹对拍。
--
-- 方法（用户 2026-09-17 纠正后）：验证 = 结构对齐而非穷举。这里把 FLT 真实定理
-- 陈述（fermats-last-theorem 仓库）作为输入，跑 trha 的 ConstraintVerdict.verdictOf，
-- 比较：① 正确陈述（真）vs ② 篡改陈述（如 a^n+b^n=c^(n+1) 假版本）的 T6 判定差异。
-- 判据：验证层是否对「数学内容差异」敏感（Pass/Warn 或 edges 变化）。
module Main (main) where

import System.Environment (getArgs)
import Infrastructure.CPU.ConstraintVerdict (verdictOf, ConstraintVerdict(..))
import Data.Char (ord)

-- FLT 真实陈述（Theorems/Thm_fermat_last_theorem.lean 的核心句）
fltTrue :: String
fltTrue = "forall n, n >= 3 -> forall a b c, a > 0 -> b > 0 -> c > 0 -> a^n + b^n ≠ c^n"

-- 篡改版（指数变 n+1——数学上完全不同的命题）
fltTampered :: String
fltTampered = "forall n, n >= 3 -> forall a b c, a > 0 -> b > 0 -> c > 0 -> a^n + b^n ≠ c^(n+1)"

-- 无意义文本（对照基线）
fltGarbage :: String
fltGarbage = "zzzz qqqq rrrr ssss tttt uuuu vvvv"

main :: IO ()
main = do
  putStrLn "=== FLT 文本 × trha 验证层（verdictOf 实弹对拍）==="
  let vTrue = verdictOf fltTrue
      vTam  = verdictOf fltTampered
      vGarb = verdictOf fltGarbage
  putStrLn ("  真实陈述:  status=" ++ show (cvStatus vTrue) ++ "  T6=" ++ show (cvT6 vTrue)
            ++ "  edges=" ++ show (cvEdges vTrue))
  putStrLn ("  篡改陈述:  status=" ++ show (cvStatus vTam) ++ "  T6=" ++ show (cvT6 vTam)
            ++ "  edges=" ++ show (cvEdges vTam))
  putStrLn ("  无意义文本: status=" ++ show (cvStatus vGarb) ++ "  T6=" ++ show (cvT6 vGarb)
            ++ "  edges=" ++ show (cvEdges vGarb))
  putStrLn ("  真vs篡改: 判定差异 = " ++ show (cvStatus vTrue /= cvStatus vTam || cvEdges vTrue /= cvEdges vTam))
  putStrLn ("  真vs乱文: 判定差异 = " ++ show (cvStatus vTrue /= cvStatus vGarb || cvEdges vTrue /= cvEdges vGarb))
  pure ()
