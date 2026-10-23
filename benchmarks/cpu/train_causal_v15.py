#!/usr/bin/env python3
"""v15：三值标签（0/0.5/1.0）——abelian 变化维度正式引入。

D2=K4 族的 del-gen0/del-comm1 删反交换 → 自由积无限且变非阿贝尔
⟹ (Δorder=1, Δabelian=1) ⟹ 复合标签 1.0（v7 起缺的 1.0 类终于有样本）。
模型：从 v9 有序回归（0/0.5）升级为**三值 softmax 分类**。
验收：能学「del-comm 在阿贝尔群上 = 1.0」而「del-comm 在非阿贝尔群上 = 0.5」
（结构特异：同是删 comm，abelian 变化是否发生取决于原群阿贝尔性）。
"""
import json, math, random, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train_causal_v9 import featurize

def softmax3(w1,w2,w3,b1,b2,b3, x):
    z1=sum(wi*xv for wi,xv in zip(w1,x))+b1
    z2=sum(wi*xv for wi,xv in zip(w2,x))+b2
    z3=sum(wi*xv for wi,xv in zip(w3,x))+b3
    mx=max(z1,z2,z3)
    e1,e2,e3=__import__('math').exp(z1-mx),__import__('math').exp(z2-mx),__import__('math').exp(z3-mx)
    s=e1+e2+e3
    return [e1/s,e2/s,e3/s]

def train3(X,y,epochs=8000,lr=0.3,seed=7,W0=None,B0=None,start_epoch=0,on_epoch=None,save_every=0):
    """y ∈ {0,0.5,1.0} → 类 {0:0, 1:0.5, 2:1.0}。三线性 softmax。
    支持热启动：W0/B0/start_epoch 来自 checkpoint → 从断点续训（不做全量重投影）。
    """
    n,d=len(X),len(X[0])
    if W0 is not None and B0 is not None:
        W=W0; B=list(B0)   # 断点恢复：用已训权重起步
    else:
        rng=random.Random(seed)
        W=[ [rng.uniform(-0.2,0.2) for _ in range(d)] for _ in range(3) ]
        B=[0.0,0.0,0.0]
    yc=[0 if v<0.25 else 1 if v<0.75 else 2 for v in y]
    for ep in range(epochs):
        grad=[ [0.0]*d for _ in range(3) ]; gb=[0.0]*3
        for xi,ci in zip(X,yc):
            p=softmax3(*W[0],*W[1],*W[2],*B[0:1],*B[1:2],*B[2:3], xi) if False else None
            # 直接算
            zs=[]
            for k in range(3):
                zs.append(sum(W[k][i]*xi[i] for i in range(d))+B[k])
            mx=max(zs); es=[math.exp(z-mx) for z in zs]; s=sum(es)
            ps=[e/s for e in es]
            for k in range(3):
                err=ps[k]-(1.0 if k==ci else 0.0)
                gb[k]+=err
                for i in range(d): grad[k][i]+=err*xi[i]
        for k in range(3):
            for i in range(d): W[k][i]-=lr*grad[k][i]/n
            B[k]-=lr*gb[k]/n
        if on_epoch and save_every>0 and (ep+1) % save_every == 0:
            on_epoch(ep+1)      # 中途存档回调（断电保护）
    return W,B

def predict3(W,B,x):
    ps=softmax3(W[0],W[1],W[2],B[0],B[1],B[2],x)
    cls=max(range(3), key=lambda k: ps[k])
    return [0.0,0.5,1.0][cls], ps

def main():
    recs=json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),"group_dataset_rel_v15.json")))
    rel_types=sorted({rt for r in recs for rt,_,_ in r["relations"]})
    from collections import Counter
    comp=Counter((r["y_order"]+r["y_abelian"])/2 for r in recs)
    print(f"=== v15 三值 · {len(recs)} 条 · 复合标签 {dict(sorted(comp.items()))} ===")
    def rows(sub):
        return [(featurize(r,rel_types),(r["y_order"]+r["y_abelian"])/2.0) for r in sub]
    X=[x for x,_ in rows(recs)]; y=[t for _,t in rows(recs)]
    W,B=train3(X,y)
    acc=sum(1 for x,v in zip(X,y) if predict3(W,B,x)[0]==v)/len(X)
    print(f"  三值训练 acc = {acc:.2f}")
    # 关键：del-comm 在阿贝尔（D2→1.0）vs 非阿贝尔（D6→0.5）上的判别
    for nm,fam in [("D2/del-comm1","Gf2x"),("D6/del-comm1","Dihedral"),("D2/del-gen0","Gf2x"),("D2/del-redundant","Gf2x")]:
        for r in recs:
            if r["name"]==nm.split("/")[0] and r["variant"]==nm.split("/")[1]:
                x=featurize(r,rel_types); v=(r["y_order"]+r["y_abelian"])/2
                pv,ps=predict3(W,B,x)
                print(f"  {r['name']:5s}/{r['variant']:12s} 真={v} 预测={pv} 分布=[{ps[0]:.2f},{ps[1]:.2f},{ps[2]:.2f}]")
                break
    # 留出：D2 族整族 unseen（训练不见 Gf2x）
    d2=[r for r in recs if r["family"]=="Gf2x"]; rest=[r for r in recs if r["family"]!="Gf2x"]
    if d2:
        Xt=[x for x,_ in rows(rest)]; yt=[t for _,t in rows(rest)]
        Xg=[x for x,_ in rows(d2)]; yg=[t for _,t in rows(d2)]
        W2,B2=train3(Xt,yt)
        ag=sum(1 for x,v in zip(Xg,yg) if predict3(W2,B2,x)[0]==v)/len(Xg)
        print(f"  留出 D2 族（{len(Xg)} unseen）泛化 acc = {ag:.2f}")
        for r,x,v in zip(d2,Xg,yg):
            pv,_=predict3(W2,B2,x)
            print(f"    {r['name']}/{r['variant']:12s} 真={v} 预测={pv}")

if __name__=="__main__": main()
