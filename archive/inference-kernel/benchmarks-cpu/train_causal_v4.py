#!/usr/bin/env python3
"""因果推理模型 · 第四版：负向控制（泛化验证）。

训练于 28 条关系级数据（group_dataset_rel.json），测试 3 个**训练未见**的新群
（C5/C7/C10 循环群，删 gen 关系 → 阶变）。若新群预测正确 ⟹ 模型学到
「删生成元关系 ⟹ 阶变化」机制而非记忆训练集；若只对训练集 acc 1.00 而对新群
预测随机 ⟹ 过拟合，需扩数据。

可复现：numpy、固定 seed、与 v3 相同编码/训练。
"""
import json
import math
import random

def featurize(r, rel_types):
    dim = len(rel_types) * 4
    bag = [0.0] * dim
    rels = r["relations"]
    masked = set(r["relations_masked"])
    for i, (rtype, param, _gorder) in enumerate(rels):
        if i in masked:
            continue
        t = rel_types.index(rtype)
        b = min(3, int(math.log(param + 1) / 1.5))
        bag[t * 4 + b] += 1.0
    bag = bag + [math.log(r["order"] + 1) / 5.0, math.log(r["new_gen_order"] + 1) / 5.0]
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
    w, b = train(X, yO)

    # 训练集 acc
    tr_acc = sum(1 for xi, yy in zip(X, yO)
                 if (sigmoid(sum(wi*xv for wi, xv in zip(w, xi)) + b) > 0.5) == (yy > 0.5)) / len(X)

    # 负向控制：3 个训练未见的新群
    new = [
      {"name": "C5",  "order": 5,  "abelian": True, "family": "Cyclic",
       "relations": [("R_gen", 5, 5)],  "relations_masked": [], "variant": "del",
       "y_order": 1, "y_abelian": 0, "new_gen_order": 2},
      {"name": "C10", "order": 10, "abelian": True, "family": "Cyclic",
       "relations": [("R_gen", 10, 10)], "relations_masked": [], "variant": "del",
       "y_order": 1, "y_abelian": 0, "new_gen_order": 5},
      {"name": "C7",  "order": 7,  "abelian": True, "family": "Cyclic",
       "relations": [("R_gen", 7, 7)],  "relations_masked": [0], "variant": "orig",
       "y_order": 0, "y_abelian": 0, "new_gen_order": 7},
    ]
    print("=== 负向控制（泛化验证）===")
    print(f"训练集 acc = {tr_acc:.2f}（28 条）")
    ok = 0
    for r in new:
        x = featurize(r, rel_types)
        p = sigmoid(sum(wi*xv for wi, xv in zip(w, x)) + b) > 0.5
        exp = r["y_order"] > 0
        ok += (p == exp)
        print(f"  新群 {r['name']}: 预测 y_order={int(p)}（期望 {r['y_order']}）{'✓' if p==exp else '✗'}")
    verdict = "泛化成立（学到机制）" if ok >= 2 else "过拟合（需扩数据）"
    print(f"泛化：{ok}/3 → {verdict}")

if __name__ == "__main__":
    main()