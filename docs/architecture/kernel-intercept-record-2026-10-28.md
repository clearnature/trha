# Frobenius 拦截判据：更正记录（2026-10-28）

## 来源与裁定

Agent Harness 内核架构设计（会话粘贴稿）提出「Frobenius 轨道不变性拦截」；
经 FML 形式化检验，原断言不成立，用户裁定采纳更正结论并归档推理模型
（`archive/inference-kernel/`，提交 `ebcf5c5`）。

## 评议结论（三条）

1. 原稿断言「非法跃迁 ⇒ 不满足 f(v) ≢ 0」**不成立**：f 是定义 GF(3^k) 的
   不可约多项式，在域内恰有 k 个根；一般元素 v 的 f(v) ≠ 0，故该判据对
   几乎所有迁移平凡为真，**无判别力**。
2. 「安全状态」「非法跃迁」在原稿未定义——三态 (0,1,2) = (拒绝,执行,挂起)
   是**设计选择**，GF(3) 的元素本身没有这些语义。
3. 更正后的可证命题（FML 已形式化）：
   - T2 Frobenius 不动点 = GF(3) 嵌入像（拦截的授权面 = 基域）；
   - T3 σ² 不动点 = 同一基域（GF(9) ∩ GF(27) = GF(3)，2 ∤ 3）；
   - T5 与 σ 交换的乘子恰为基域——非基域乘子必把基态推离其轨道。

## 内核侧落地状态

- **C5 判定已解耦重建**：`Core.Sov.ConstraintVerdict`（src/core/Sov/，
  2026-10-28 入 trha-core）——响应侧 pass/warn 标注、不拒绝（裁定①）；
  API.Server 的 constraintField / trha_constraint / t6_state 投影已恢复
  （trha-test 内 C5×4 + D-3×4 全绿）。
- **推理模型本体已归档**：`archive/inference-kernel/`；重推理链（60 层
  前向/checkpoint 读取）随模型离场，需要时 `git log --follow` 找回。
- **调度器实例已停**：pid 1070836（9h16m）已停，陈旧 pid 文件已清。

## 可执行判据的正确形态

- 基域驻留检验：坐标 b = c = 0（GF(3) 嵌入像）⇒ 授权面；
- 交换性检验：σ(a·1) = a·σ(1) ⇔ a ∈ 基域 ⇒ 非基域乘子必破坏交换性；
- 两者都是 27 步可判定的纯函数（见 FML `Intercept.agda` 的枚举 pin 与
  trha-test 的 C5 断言），不依赖任何权重文件或外部模型。
