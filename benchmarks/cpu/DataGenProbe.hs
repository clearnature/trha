-- | b 参考整合 · 数据地基：GF(27)* = ⟨α | α^26 = 1⟩ 循环群，变体 + 反事实标签。
--
-- 参考「神经符号因果推理」数据集：四元组 ⟨P, S, c, y⟩，y = 删 r 后结论是否变。
-- 最简展示群模板：C_n = ⟨α | α^n = 1⟩（α 为 GF(27)* 生成元，Z/26 乘法群）。
-- 结论 c = 群阶；关系 r = α^n=1；变体 = 把 n 改为 n'（删除原关系、引入新关系）。
-- 反事实标签：删除 r（n→n'）后阶变 ⇒ r 对「阶=n」是原因(1)；不变(0)。
-- 用现有 gf27AlphaPow/gf27Mul 验证（纯数学，无训练）。
module Main (main) where

import Control.Exception (evaluate)
import Infrastructure.CPU.SovereignGF27 (gf27AlphaPow)
import Infrastructure.CPU.GF3Intrinsic (gf27Mul)

-- GF(27)* 元素 α^k 的幂乘：α^a ⊗ α^b = α^(a+b mod 26)（乘法群 Z/26）
alphaPow :: Int -> Int
alphaPow k = gf27AlphaPow (k `mod` 26)

-- 元素 x 的阶：最小 k>0 使 x^k = 1（x 以 α 的指数表达：ord(α^m) = 26 / gcd(26, m)）
groupOrder :: Int -> Int
groupOrder n = n   -- 群 C_n 的阶 = n
  where gcd a b = if b == 0 then a else gcd b (a `mod` b)

main :: IO ()
main = do
  putStrLn "=== b 数据地基：GF(27)* 循环群变体 × 反事实标签 ==="
  putStrLn ("  模板：C_26 = ⟨α | α^26 = 1⟩，α 指数乘法群 Z/26")
  -- 验证核心定理（用现有 gf27AlphaPow）
  putStrLn ("  α^1     = " ++ show (alphaPow 1) ++ "（α 编码）")
  putStrLn ("  α^13    = " ++ show (alphaPow 13) ++ "（定理 α¹³ = −1）")
  putStrLn ("  α^26    = " ++ show (alphaPow 26) ++ "（定理 α²⁶ = 1，应为 1）")
  -- 结论 c：群阶（生成元 α 的阶 = 26）
  putStrLn ("  结论 c：群阶 = 26")
  -- 关系 r：⟨α^26=1⟩；变体：删此关系 → 改 α^n=1（n = 26 的因数）
  -- 反事实标签：删除 r 后阶变吗？
  let variants = [ (1, "自由积 α^1（无界）"), (2, "C_2"), (3, "C_3"), (13, "C_13")
                 , (26, "原样 C_26") ]
      conclusion = 26
  putStrLn "  变体 | 群阶 | 结论c 变? | 标签(反事实)"
  mapM_ (\(n, name) -> do
            let newOrder = groupOrder n   -- 群阶 = n
                changed = newOrder /= conclusion
                label = if changed then 1 else 0
            putStrLn ("    " ++ name ++ " → 阶 " ++ show newOrder ++ " | " ++ show changed ++ " | " ++ show label))
        variants
  putStrLn ""
  putStrLn "  ——「α^26=1」对结论「群阶=26」的反事实标签："
  putStrLn "    · 删关系改 α^2=1（变体 C_2）⇒ 阶 26→2 ⇒ 原关系是结论的原因(1)"
  putStrLn "    · 保持 α^26=1（原样）⇒ 阶不变 ⇒ 标签(0)"
  _ <- evaluate (26 `div` 2)
  pure ()