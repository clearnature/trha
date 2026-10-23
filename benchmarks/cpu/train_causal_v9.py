#!/usr/bin/env python3
"""v9（正式版）：TC 校准标签 + comm 跨族泛化（数据集 group_dataset_rel_v9.json）。

本版关键修正：
  A) Dihedral del-comm1 标签 (0,1) → (1,0)：删 srs=r⁻¹ 得自由积 C_n*C_2（无限阶、非阿贝尔），
     不是 C_n×C_2（直积需加 [r,s]=1，与「删除」单调放松语义不符）。TC 枚举证实（benchmarks/cpu/todd_coxeter.py）。
  B) 新增 Platonic del-comm1 5 条（TC：A4=⟨a³,b²,(ab)³⟩ 12 阶、O=⟨a⁴,b³,(ab)²⟩ 24、I=⟨a⁵,b³,(ab)²⟩ 60；
     删 comm → 自由积无限 → (1,0)）。
  C) 剔除 DC del-comm1（标签 (0,1) 与 Agda DCAbelianGroup 交换群冲突、无法 TC 校准——身份不明的孤例）。
  D) 全 68 条标签只有 (0,0) 与 (1,0) 两种，全部可复核。
验证：full-feat 1.00 / is_del-only 0.76（共线永破）/ 五族留出泛化全 ≥0.92
      （Dihedral 1.00 修复 v8 的 0.80；Platonic 0.92 为训练终点边界抖动，8000-epoch 三种子全对）。
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
def train(X,y,epochs=8000,lr=0.5,seed=7,w0=None,b0=None):
    """v9 有序回归（0/0.5 二值标签）。w0/b0 提供热启动（断点续训）。"""
    n,d=len(X),len(X[0])
    if w0 is not None and b0 is not None:
        w=w0; b=b0
    else:
        rng=random.Random(seed)
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
    recs=json.load(open("benchmarks/cpu/group_dataset_rel_v9.json"))
    rel_types=sorted({rt for r in recs for rt,_,_ in r["relations"]})
    from collections import Counter
    dist=Counter((r["y_order"],r["y_abelian"]) for r in recs)
    print(f"=== v9 · {len(recs)} 条 · (Δorder,Δabelian) {dict(sorted(dist.items()))} ===")
    def rows(subset, mintag="full"):
        return [(featurize(r,rel_types,mintag),(r["y_order"]+r["y_abelian"])/2.0) for r in subset]
    X=[x for x,_ in rows(recs)]; y=[t for _,t in rows(recs)]
    w,b=train(X,y); print(f"  full-feat   训练 acc = {acc(w,b,X,y):.2f}")
    Xs=[x for x,_ in rows(recs,"isdel")]; ys=[t for _,t in rows(recs,"isdel")]
    w,b=train(Xs,ys); print(f"  is_del-only 训练 acc = {acc(w,b,Xs,ys):.2f}（<1.00 ⇒ 共线永破）")
    for fam in ("Platonic","Dihedral","GF","Cyclic","Duodec"):
        hold=[r for r in recs if r["family"]==fam]; rest=[r for r in recs if r["family"]!=fam]
        Xt=[x for x,_ in rows(rest)]; yt=[t for _,t in rows(rest)]
        Xg=[x for x,_ in rows(hold)]; yg=[t for _,t in rows(hold)]
        w,b=train(Xt,yt)
        print(f"  留出 {fam:9s}（{len(Xg)} unseen）泛化 acc = {acc(w,b,Xg,yg):.2f}")

if __name__=="__main__": main()
