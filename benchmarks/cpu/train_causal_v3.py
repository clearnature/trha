#!/usr/bin/env python3
"""因果推理模型 · 第三版：L1 关系级符号编码 + 关系→结论消息传递（参考 L1+L2 最小版）

数据：group_dataset_rel.json（28 条，每条 relations_masked = 被删除的关系索引）。
建模：
  - L1 编码：每组的关系集 → bag-of-relations 向量（3 型：gen/comm/pow × 阶参数 → 特征）
  - 删除关系 = 分量置零（掩码）
  - L2 消息传递：W_rel @ bag（可学习）→ 群表示 → sigmoid 预测 y_order
训练目标：y_order（变体删生成元关系 → 阶变 = 1）。判据：从 v2 的 0.65 提升。

可复现：numpy 手写、固定 seed、确定性变体掩码。
"""
import json
import math
import random

def featurize(r, rel_types):
    """bag-of-relations：对每条存在的关系，按其类型和阶参数生成特征分量。
    掩码：被删的关系对应位置置 0。"""
    dim = len(rel_types) * 4  # 每型 4 个阶 bin
    bag = [0.0] * dim
    rels = r["relations"]
    masked = set(r["relations_masked"])
    for i, (rtype, param, _gorder) in enumerate(rels):
        if i in masked:
            continue
        t = rel_types.index(rtype)
        # 阶参数分桶（如 3/4/9/12/26/120 → log 分 4 区）
        b = min(3, int(math.log(param + 1) / 1.5))
        bag[t * 4 + b] += 1.0
    # 附群级特征（保留但不再主导）
    bag = bag + [math.log(r["order"] + 1) / 5.0,
                 math.log(r["new_gen_order"] + 1) / 5.0]
    return bag

def sigmoid(z):
    return 1.0 / (1.0 + math.exp(-z))

def train(X, y, epochs=3000, lr=0.3):
    n, d = len(X), len(X[0])
    rng = random.Random(7)
    w = [rng.uniform(-0.2, 0.2) for _ in range(d)]
    b = 0.0
    for _ in range(epochs):
        gw = [0.0] * d
        gb = 0.0
        for xi, yi in zip(X, y):
            p = sigmoid(sum(wi * xv for wi, xv in zip(w, xi)) + b)
            err = p - yi
            for k in range(d):
                gw[k] += err * xi[k]
            gb += err
        for k in range(d):
            w[k] -= lr * gw[k] / n
        b -= lr * gb / n
    return w, b

def main():
    recs = json.load(open("benchmarks/cpu/group_dataset_rel.json"))
    rel_types = sorted({rt for r in recs for rt, _, _ in r["relations"]})
    X = [featurize(r, rel_types) for r in recs]
    yO = [1.0 if r["y_order"] == 1 else 0.0 for r in recs]
    yA = [1.0 if r["y_abelian"] == 1 else 0.0 for r in recs]

    print("=== 因果推理模型 · 第三版（L1 关系编码 + 消息传递）===")
    print(f"数据 {len(recs)} 条 · 特征维 {len(X[0])} · 关系型 {rel_types}")
    for name, y in [("变体→阶变(原因)", yO), ("变体→阿贝尔变(原因)", yA)]:
        w, b = train(X, y)
        acc = sum(1 for xi, yy in zip(X, y)
                  if (sigmoid(sum(wi * xv for wi, xv in zip(w, xi)) + b) > 0.5) == (yy > 0.5)) / len(X)
        print(f"  任务「{name}」acc = {acc:.2f}")
    # 看学到的关系权重（解释模型学了什么）：W_rel 前 4 维（gen 型 bin0..3）
    w, b = train(X, yO)
    print(f"  y_order 学的 gen 关系权重 = {[round(v, 2) for v in w[:4]]}（删 gen → 分量置零 → 负贡献？）")

if __name__ == "__main__":
    main()