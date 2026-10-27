#!/usr/bin/env python3
"""v8（正式版）：is_del 共线打破后的因果角色判别（数据集 group_dataset_rel_v8.json）。

数据修正（v8b 构造）：完整演示集 regs + R_gen_red（冗余 relator），
  masked = 被删关系索引（orig=[]，del-gen0=[0]，del-gen1=[1]，
  del-comm1=[comm_idx]，del-redundant=[red_idx]）。
  标签 = (Δy_order + Δy_abelian)/2 ∈ {0, 0.5}（复合结论 explicitization）。

验证四点：
  1. full-feat 训练 acc = 1.00（模型学「关系类型因果角色」）
  2. is_del-only = 0.75 < 1.00（共线已破：删不等于变）
  3. 留出 Platonic 泛化 = 1.00（unseen 家族全对）
  4. 留出 Dihedral 泛化 = 0.80 —— comm 语义跨族泛化未达验收（训练仅见过 DC 一族 1 条 comm 样本）
"""
import json, math, random

def featurize(r, rel_types, mintag="full"):
    bag=[0.0]*(len(rel_types)*4)
    masked=set(r["relations_masked"])
    for i,(rt,p,_) in enumerate(r["relations"]):
        if i in masked: continue
        t=rel_types.index(rt); b=min(3,int(math.log(p+1)/1.5))
        bag[t*4+b]+=1.0
    is_del=1.0 if r["relations_masked"] else 0.0
    if mintag=="full":  return bag+[math.log(r["order"]+1)/5.0, math.log(r["new_gen_order"]+1)/5.0, is_del]
    if mintag=="isdel": return [is_del]
    return bag

def sigmoid(z): return 1.0/(1.0+math.exp(-z))
def train(X,y,epochs=6000,lr=0.4,seed=7):
    n,d=len(X),len(X[0]); rng=random.Random(seed)
    w=[rng.uniform(-0.2,0.2) for _ in range(d)]; b=0.0
    for _ in range(epochs):
        gw=[0.0]*d; gb=0.0
        for xi,yi in zip(X,y):
            p=sigmoid(sum(wi*xv for wi,xv in zip(w,xi))+b)
            err=(p-yi)*p*(1.0-p)
            for k in range(d): gw[k]+=err*xi[k]
            gb+=err
        for k in range(d): w[k]-=lr*gw[k]/n
        b-=lr*gb/n
    return w,b
def pred(w,b,x): return sigmoid(sum(wi*xv for wi,xv in zip(w,x))+b)
def bucket(p): return 0 if p<0.25 else 1 if p<0.75 else 2
def acc(w,b,X,y): return sum(1 for x,yi in zip(X,y) if bucket(pred(w,b,x))==bucket(yi))/len(X)

def main():
    recs=json.load(open("benchmarks/cpu/group_dataset_rel_v8.json"))
    rel_types=sorted({rt for r in recs for rt,_,_ in r["relations"]})
    def rows(subset, mintag):
        return [(featurize(r,rel_types,mintag),(r["y_order"]+r["y_abelian"])/2.0) for r in subset]
    from collections import Counter
    print(f"=== v8 · {len(recs)} 条 · 标签 {dict(sorted(Counter((r['y_order']+r['y_abelian'])/2 for r in recs).items()))} ===")
    X=[x for x,_ in rows(recs,"full")]; y=[t for _,t in rows(recs,"full")]
    w,b=train(X,y); print(f"  full-feat    训练 acc = {acc(w,b,X,y):.2f}")
    Xs=[x for x,_ in rows(recs,"isdel")]; ys=[t for _,t in rows(recs,"isdel")]
    w,b=train(Xs,ys); print(f"  is_del-only  训练 acc = {acc(w,b,Xs,ys):.2f}（<1.00 ⇒ 共线已破）")
    for fam in ("Platonic","Dihedral"):
        hold=[r for r in recs if r["family"]==fam]; rest=[r for r in recs if r["family"]!=fam]
        Xt=[x for x,_ in rows(rest,"full")]; yt=[t for _,t in rows(rest,"full")]
        Xg=[x for x,_ in rows(hold,"full")]; yg=[t for _,t in rows(hold,"full")]
        w,b=train(Xt,yt)
        print(f"  留出 {fam:9s}（{len(Xg)} unseen）泛化 acc = {acc(w,b,Xg,yg):.2f}")

if __name__=="__main__": main()
