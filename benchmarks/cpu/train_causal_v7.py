#!/usr/bin/env python3
"""v7：partial 三值标签（复合结论 explicitization）。

参考审查「需进一步细化」的 0.5 档，在 trha 语境明确化为：
  结论集 C = {c_order（阶精确值）, c_abelian（阿贝尔性）}
  删关系集 M 后，标签 y = (Δc_order + Δc_abelian) / count(C) ∈ {0, 0.5, 1.0}
    - 0.0：结论全部不变（orig）
    - 0.5：恰好一个结论变（partial —— 删关系只破坏一部分结论）
    - 1.0：全部结论变（完整因果）

模型：有序回归（ordinal，单输出 prob = 变更比例），验证：
  a) 训练 acc（0 vs 0.5 可分）
  b) DC del-comm1（唯一 y_abelian=1 的行）预测 prob 应 ≈ 0.5（中间响应）
  c) 发现性检查：数据里 1.0 类别是否存在？（预期：不存在——代数正交性事实）
"""
import json, math, random

def featurize(r, rel_types):
    dim=len(rel_types)*4; bag=[0.0]*dim
    masked=set(r["relations_masked"])
    for i,(rt,p,_) in enumerate(r["relations"]):
        if i in masked: continue
        t=rel_types.index(rt); b=min(3,int(math.log(p+1)/1.5))
        bag[t*4+b]+=1.0
    is_del=1.0 if r["relations_masked"] else 0.0
    return bag+[math.log(r["order"]+1)/5.0, math.log(r["new_gen_order"]+1)/5.0, is_del]

def sigmoid(z): return 1.0/(1.0+math.exp(-z))

def build():
    recs=json.load(open("benchmarks/cpu/group_dataset_rel.json"))
    rel_types=sorted({rt for r in recs for rt,_,_ in r["relations"]})
    rows=[]
    for r in recs:
        # 复合标签：变更的结论数 / 2（结论集 = {order, abelian}）
        lab=(r["y_order"]+r["y_abelian"])/2.0
        rows.append((featurize(r,rel_types), lab))
    return rows, rel_types

def train_ordinal(X,y,epochs=5000,lr=0.4,seed=7):
    """有序回归：单 logit 预测变更比例 ∈ [0,1]，损失 = 均方，输出可解释为中间概率。"""
    n,d=len(X),len(X[0]); rng=random.Random(seed)
    w=[rng.uniform(-0.2,0.2) for _ in range(d)]; b=0.0
    for _ in range(epochs):
        gw=[0.0]*d; gb=0.0
        for xi,yi in zip(X,y):
            p=sigmoid(sum(wi*xv for wi,xv in zip(w,xi))+b)
            err=(p-yi)*p*(1.0-p)   # 标准 sigmoid 回归梯度
            for k in range(d): gw[k]+=err*xi[k]
            gb+=err
        for k in range(d): w[k]-=lr*gw[k]/n
        b-=lr*gb/n
    return w,b

def main():
    rows,rel_types=build()
    X=[x for x,_ in rows]; y=[t for _,t in rows]
    from collections import Counter
    dist=Counter(y)
    print(f"=== v7 partial 三值 · {len(rows)} 条 · 标签分布 {dict(sorted(dist.items()))} ===")
    print(f"  ⚠ 发现：1.0（完整因果）类别 {'存在' if dist.get(1.0) else '**不存在**（现数据无一关系删除同时改变阶+阿贝尔性）'}")

    w,b=train_ordinal(X,y)
    preds=[sigmoid(sum(wi*xv for wi,xv in zip(w,x))+b) for x in X]
    # a) 三档分区（0 → <0.25，0.5 → [0.25,0.75]，1.0 → >0.75）
    acc=0
    for x,yi in zip(X,y):
        p=sigmoid(sum(wi*xv for wi,xv in zip(w,x))+b)
        bucket=(0 if p<0.25 else 1 if p<0.75 else 2)
        yb=(0 if yi<0.25 else 1 if yi<0.75 else 2)
        acc+= (bucket==yb)
    acc/=len(X)
    print(f"  三档（0/0.5/1 区间划分）训练 acc = {acc:.2f}")

    # b) 关键：partial 行的 prob 分布 vs orig 行
    orig_p=[p for x,yi in zip(X,y) if yi==0.0 for p in [sigmoid(sum(wi*xv for wi,xv in zip(w,x))+b)]]
    part_p=[p for x,yi in zip(X,y) if yi==0.5 for p in [sigmoid(sum(wi*xv for wi,xv in zip(w,x))+b)]]
    print(f"  orig(y=0)   prob: min={min(orig_p):.2f} max={max(orig_p):.2f} mean={sum(orig_p)/len(orig_p):.2f}")
    print(f"  partial(0.5) prob: min={min(part_p):.2f} max={max(part_p):.2f} mean={sum(part_p)/len(part_p):.2f}")
    sep=min(part_p)-max(orig_p)
    print(f"  分界余量（min partial − max orig）= {sep:+.2f}  →  {'可分 ✓' if sep>0.05 else '重叠 ✗'}")

    # c) 细查：DC del-comm1（唯一阿贝尔变化的行）预测 prob
    for r in json.load(open("benchmarks/cpu/group_dataset_rel.json")):
        if r["variant"]=="del-comm1":
            x=featurize(r,rel_types)
            p=sigmoid(sum(wi*xv for wi,xv in zip(w,x))+b)
            print(f"  DC del-comm1（变阿贝尔、不变阶 → 标签 0.5）预测 prob = {p:.2f}（应≈0.5 中间响应）")

if __name__=="__main__": main()
