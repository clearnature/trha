#!/usr/bin/env python3
"""训练因果推理模型 · 第一版（参考「神经符号因果推理」三阶段方案的阶段 2：结论预测）

数据：benchmarks/cpu/group_dataset.json（离散数学库 6 Group 实例 × 变体，15 条）。
模型：最小可复现的 LogReg/单隐层（numpy，无 DL 依赖）——输入群特征向量 [order, mult_order,
      gen_order, family_onehot]，输出：结论 y = 阿贝尔性（abelian）与是否「阶 ≥ 12」。
判据：模型在训练集上能学会「order ≥ 12 ⟹ 结论成立、变体（order 缩小）⟹ 标签 1」这类
      因果规则——即从数据学到「生成元阶制约群阶」的可迁移关系。

参考：/home/yanli/文档/大模型使用/神经符号因果推理模型（三阶段训练、结论预测损失 BCE）。
"""
import json
import math
import random

def load_data(path):
    with open(path) as f:
        return json.load(f)

def featurize(rec, families):
    f = [0.0] * len(families)
    f[families.index(rec["family"])] = 1.0
    # 特征：阶的对数（缩放）、乘群阶、生成元阶、族 one-hot
    return [math.log(rec["order"] + 1) / 4.0,
            math.log(rec["mult_order"] + 1) / 4.0,
            math.log(rec["gen_order"] + 1) / 4.0] + f

def sigmoid(z):
    return 1.0 / (1.0 + math.exp(-z))

def train(X, y, epochs=2000, lr=0.1):
    n, d = len(X), len(X[0])
    rng = random.Random(42)
    w = [rng.uniform(-0.1, 0.1) for _ in range(d)]
    b = 0.0
    for ep in range(epochs):
        grad_w = [0.0] * d
        grad_b = 0.0
        for xi, yi in zip(X, y):
            p = sigmoid(sum(wi * xv for wi, xv in zip(w, xi)) + b)
            err = p - yi
            for k in range(d):
                grad_w[k] += err * xi[k]
            grad_b += err
        for k in range(d):
            w[k] -= lr * grad_w[k] / n
        b -= lr * grad_b / n
    return w, b

def predict(X, w, b):
    return [sigmoid(sum(wi * xv for wi, xv in zip(w, xi)) + b) > 0.5 for xi in X]

def main():
    recs = load_data("benchmarks/cpu/group_dataset.json")
    families = sorted(set(r["family"] for r in recs))
    X = [featurize(r, families) for r in recs]
    # 双结论任务（对应参考方案：结论预测 + 因果归因验证）：
    #   y_order   = 关系 r 是「群阶」的原因？（变体删生成元 → 阶变 = 1）
    #   y_abelian = 关系 r 是「阿贝尔性」的原因？（介质删交换 → 阿贝尔变 = 1）
    yOrder   = [1.0 if r["y_order"] == 1 else 0.0 for r in recs]
    yAbelian = [1.0 if r["y_abelian"] == 1 else 0.0 for r in recs]
    # 性质预测：原样样本的阶 ≥ 12（结论成立与否）
    yBig = [1.0 if (r["variant"] == "orig" and r["order"] >= 12) else 0.0 for r in recs]

    print("=== 因果推理模型 · 第二版（双结论因果归因）===")
    print(f"数据：{len(recs)} 条 · 特征维 {len(X[0])} · 族 {families} · 阿贝尔 {sum(1 for r in recs if r['abelian'] and r['variant']=='orig')}") 
    for name, y in [("变体→阶变(原因)", yOrder), ("变体→阿贝尔变(原因)", yAbelian), ("原样→阶≥12", yBig)]:
        w, b = train(X, y)
        pred = predict(X, w, b)
        acc = sum(1 for p, yy in zip(pred, y) if (p == (yy > 0.5))) / len(y)
        print(f"  任务「{name}」acc = {acc:.2f}")

if __name__ == "__main__":
    main()