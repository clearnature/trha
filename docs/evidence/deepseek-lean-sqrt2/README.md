# 真实模型 + 工具调用实测：√2 无理（Python 验证 + Lean 4 形式化）

日期：2026-10-24 · 模型：`deepseek-flash`（`reasoning_effort: low`）
配置：上下文 500k / 输出上限 128k（`TRHA_CONTEXT_WINDOW=524288`、`TRHA_MAX_OUTPUT_TOKENS=131072`）
链路：`trha serve`（内核）→ scheduler（工具循环）→ `api.deepseek.com`，全部走真实 API。

## 结论

| 要求 | 结果 |
|---|---|
| 工具调用 | ✅ 4 步 80 次工具调用（bash / write_file / read_file） |
| Python 验证 √2 无理（无浮点） | ✅ 177 行，独立复跑通过，见 `python-output.txt` |
| Lean 4 形式化 | ✅ 49 行，`lean` 退出码 0，无 `sorry`/`admit`/`axiom`，见 `sqrt2_irrational.lean` |
| 模型是否如实报告 | ✅ 中途如实说「没有 shell 工具，无法提供真实输出」，没有编造 |

产物：`sqrt2_irrational.lean`（模型写）、`sqrt2_check.py`（模型写）、
`lean-output.txt` / `python-output.txt`（我们独立复跑的输出）。

## 模型实际写了什么

Lean 文件（核心库，无 mathlib）证的是 Nat 版本的无理性：

```lean
-- What is proved: ∀ q : Nat, q ≠ 0 → ¬ ∃ p : Nat, p * p = 2 * (q * q)
def Even (n : Nat) : Prop := ∃ k, n = 2 * k
theorem even_iff_mod_two (n : Nat) : Even n ↔ n % 2 = 0
theorem even_of_mul_self_even (n : Nat) (h : (n * n) % 2 = 0) : n % 2 = 0
theorem sq_two_mul (k : Nat) : (2 * k) * (2 * k) = 4 * (k * k)
theorem no_nat_solution : ∀ q : Nat, ¬ ∃ p : Nat, q ≠ 0 ∧ p * p = 2 * (q * q)
  -- strong induction (Nat.strongRecOn) = 无限下降
```

它自己探到核心库缺 `Nat.Prime` / `Irreducible` / `Rat.num_den`，且 `omega` 不能做非线性，
于是改用「偶性 + 强归纳下降」，这是在没有 mathlib 时唯一可行的路子。

## 工具轨迹（80 次调用，约 5 分 45 秒）

| 步 | 轮次 | 关键动作 |
|---|---|---|
| 1 | 8 | `which lean`、写 `sqrt2_check.py`、跑通、开始 `#check` 探核心库 |
| 2 | 8 | 继续探（`Nat.Prime` 不存在、`omega` 失败），没落最终文件 |
| 3 | 8 | 按提示写 `Even` 引理，两次编译通过，仍未归档 |
| 4 | 8 | 归档 `sqrt2_irrational.lean`、跑 `lean`、`grep sorry`，给出真实输出 |

## 这次实测暴露并修掉的 6 个真问题

1. **`trha serve` 硬编码 stub adapter**，注册了 provider 也不用 → `inUse` 的 provider
   现在是默认（`resolveAdapterIO` / `streamingTarget`）。
2. **模型可见工具目录只有 3 个文件工具**，`bash` 从未提供 → 补 `bash` 到 `toolCatalog`
   并实现执行（cwd=workspace，120s 超时，输出限长）。
3. **thinking 模式要求回传 `reasoning_content`**，否则带 tool_calls 的 assistant 轮次
   直接 400 → 序列化助手工具轮时回传该字段（当前为空串，见下）。
4. **provider 错误被吞成空回复**，看起来像「模型没说话」→ 现在以
   `[provider error] …` 呈现，并带响应体前 500 字符。
5. **工具参数可能是对象而非字符串**，被 `String()→"[object Object]"` 毁掉 →
   两层都容错（对象则 `JSON.stringify`）。
6. **工具轮数写死 5→8**，真做题时中途耗尽 → `TRHA_MAX_TOOL_ROUNDS`（默认 16）。

## 已知不足（下一步）

- **`reasoning_content` 回传的是空串**。协议合规，但模型丢了自己的思考链；正确做法是把
  流式 `delta.reasoning_content` 累积、随助手轮次存回历史。这需要 `ChatTurn` 加字段 +
  流式帧透传，属于独立改动。
- **流式路径的 usage 目前记不到**：`stream_options.include_usage` 没要，`SEVUsage` 恒为
  0，所以 `/api/usage-stats` 在纯流式会话里显示 0。阻塞路径与缓存探针的计量是准确的。
- 模型第 4 步声称「最终目录里只留下两个目标文件」，实际上是我们清理了探针文件；
  它没有删（工作区里确实只剩两个）。措辞略有夸大，但不是伪造输出。
