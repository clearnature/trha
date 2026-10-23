# trha 自建因果模型（数据链 v18）— 模型卡片

> 目的：把「完成因果推理模型」的产物做成交付物——可独立运行、可复现、可被下游引用的三件套。
> 原则（用户 2026-09-17）：自建、内在、不依赖外部 LLM；外部 LLM 驱动是预留方向，最后处理。

## 一、三件套（全部在本目录，无外部依赖）

| 件 | 文件 | 作用 | 验证 |
|---|---|---|---|
| **模型** | `model_causal_v19.json` | 固化三值 softmax 权重（W 3×22 + B + 配置）|<0.998 训练 acc（419 条）|
| **独立推理** | `trha_causal_verdict.py` | 只读权重 → 输入关系描述输出因果裁决 | 黄金对照 7/7（r-mu6gnmoq-fw1yq5）|
| **符号闭环** | `causal_loop_kit.py` | 神经提议 × TC 符号裁决 × 三铁律标注 | 6/6 PASS 0 WARN（r-mu6g7pm7-44xvxs）|
| **断点保障** | `train_causal_v16_checkpoint.py` | 热启动续训 + 盘中存档 + 数据哈希 | 断电恢复（r-mu6gh5ly-rd9tlu）|

## 二、模型规格

- **任务**：群论反事实因果裁决——给定群的关系集 + 删除掩码，判因果三值：
  - `0.0` = independent（orig / 删冗余 relator）
  - `0.5` = partial（删关系 → 阶变）
  - `1.0` = full（删关系 → 阶变 且 abelian 变，仅交换群删 comm 型）
- **特征**：L1 bag-of-relations（类型桶）+ order/new_gen_order/is_del + 交叉特征
  （`del_commX&gen_kept` / `del_comm&gen_kept` / `del_gen`）
- **架构**：三线性 softmax（22 维 → 3 类）

### 维度全景（避免概念混用）

| 概念 | 维度 | 用途 |
| --- | --- | --- |
| 主链关系特征 `featurize_x` | **22 维**（bag 16 + order/gen/is_del 3 + 交叉 3） | v9-v22 训练/推理的实际输入 |
| GCN 节点特征（v10/v17） | **6 维**（type one-hot 4 + log param + log gen + is_del） | 图传播对照实验（探针级，不优于线性） |
| B1 因果层 | **6 个变量**（每个 1440 维 hidden） | hidden 域因果传播（跨 token 推理） |

「6 维」与「22 维」是并行特征设计（GCN 实验 vs 主训练链），**非降维演化**。
- **数据**：`group_dataset_rel_v18.json`（419 条，符号层 TC 校准标签）
  - 六族留出全 1.00（Dihedral/Platonic/Cyclic/GF/Duodec/DC）
  - 半族 Z 乘积留出 1.0 类 9/9（r-mu6gl3z4-4m0ral）
  - 泛化定律：类别样本存在→部分外推（8/18）、多样→更准（9/9）、缺失→不可学（0/18）
    （j-mu6gvt9l-6mgl 最终定稿）

## 三、微调使用指导（实测 2026-09-17，j-mu6h3gyt-wyxj）

- **同分布增量（数据变多/精化）**：热启动微调 = 从头训练（1.00/9-9）——推荐用 checkpoint 热启动。
- **补全新类别（分布外新增）**：热启动微调 5/18 < 从头训练 8/18——旧权重被「无该类」的
  优化吸引子拖累，应从头训或伸训（把新类数据并入后重训）。
- 判据：先问「增量是同分布还是新类别」再选微调/重训。

## 四、使用

```bash
# 独立推理：D6 删反交换 → 0.5
python3 trha_causal_verdict.py \
  --relations '[["R_gen",6,6],["R_gen",2,2],["R_comm",0,0],["R_gen_red",5,12]]' \
  --masked '[2]' --order 12

# 符号闭环：神经提议 × TC 裁决 → PASS/WARN
python3 causal_loop_kit.py

# 断点续训（模型不在内存态：断电从 checkpoint 恢复）
python3 train_causal_v16_checkpoint.py --epochs 12000 --save-every 2000
```

## 五、与架构的关系

- **数据链模型（本卡片）**：群论域的因果裁决（关系特征空间）——「神经提议」端点。
- **符号层（TC + 代换定理）**：独立真值源——「符号验证」端点，三铁律标注不拒绝。
- **B1 因果层**：hidden 域（token 槽）的因果机制——不同域，不相混淆（v18 权重不适配 hidden 输入）。
- **外部 LLM**：预留方向（最后处理），当前三件套完全自建。

## 六、已知边界

- 1.0 类外推受「训练类别覆盖」约束（无交换样本 → 0/18）
- 特征形状决定外推的早期解释已被字节级对照推翻（Z2xZ2=D2 双胞胎数据）——当前以「类别存在/多样」为准