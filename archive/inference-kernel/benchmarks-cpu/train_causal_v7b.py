#!/usr/bin/env python3
"""v7b：负向控制 + 留一族泛化（v7 的对抗性检查）。

控制 1（is_del shortcut）：只给 is_del 特征（不给关系 bag）→ acc 应显著下降；
  证明模型学的是「哪种关系被删」而非「有没有删」。
控制 2（随机标签）：y 打乱 → acc 应≈随机；
  证明 acc=1.00 不是过拟合噪音。
泛化：留出 Platonic 族（12/24/48/60/120，全 unseen）→ 在留出族上按 0.25/0.75 档判 acc。
"""
import json, math, random

def featurize(r, rel_types, mintag):
    bag=[0.0]*(len(rel_types)*4)
    masked=set(r["relations_masked"])
    for i,(rt,p,_) in enumerate(r["relations"]):
        if i in masked: continue
        t=rel_types.index(rt); b=min(3,int(math.log(p+1)/1.5))
        bag[t*4+b]+=1.0
    is_del=1.0 if r["relations_masked"] else 0.0
    if mintag=="full":   return bag+[math.log(r["order"]+1)/5.0, math.log(r["new_gen_order"]+1)/5.0, is_del]
    if mintag=="isdel":  return [is_del]
    if mintag=="order":  return [math.log(r["order"]+1)/5.0, is_del]

def sigmoid(z): return 1.0/(1.0+math.exp(-z))

def train(X,y,epochs=5000,lr=0.4,seed=7):
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

def bucket_acc(w,b,X,y):
    ok=0
    for x,yi in zip(X,y):
        p=sigmoid(sum(wi*xv for wi,xv in zip(w,x))+b)
        bucket=(0 if p<0.25 else 1 if p<0.75 else 2)
        yb=(0 if yi<0.25 else 1 if yi<0.75 else 2)
        ok+= bucket==yb
    return ok/len(X)

def main():
    recs=json.load(open("benchmarks/cpu/group_dataset_rel.json"))
    rel_types=sorted({rt for r in recs for rt,_,_ in r["relations"]})
    def rows_for(subset, mintag):
        rows=[]
        for r in subset:
            lab=(r["y_order"]+r["y_abelian"])/2.0
            rows.append((featurize(r,rel_types,mintag), lab))
        return rows

    train_rows=rows_for(recs,"full"); X=[x for x,_ in train_rows]; y=[t for _,t in train_rows]

    print("=== v7b 负向控制 + 泛化 ===")
    # 控制 1：is_del only
    Xs=[x for x,_ in rows_for(recs,"isdel")]; ys=[t for _,t in rows_for(recs,"isdel")]
    w,b=train(Xs,ys); print(f"  控制1 is_del-only  训练 acc = {bucket_acc(w,b,Xs,ys):.2f}（应 < 0.85 → 非 shortcut）")
    # 控制 2：随机标签
    rng=random.Random(99); yr=list(y); rng.shuffle(yr)
    w,b=train(X,yr); print(f"  控制2 随机标签     训练 acc = {bucket_acc(w,b,X,yr):.2f}（应 ≈0.5+ → 非噪音）")
    # 主模型
    w,b=train(X,y); print(f"  主模型 full-feat   训练 acc = {bucket_acc(w,b,X,y):.2f}")

    # 泛化：留出 Platonic（非阿贝尔、大阶、未见）
    plat=[r for r in recs if r["family"]=="Platonic"]
    rest=[r for r in recs if r["family"]!="Platonic"]
    Xt=[x for x,_ in rows_for(rest,"full")]; yt=[t for _,t in rows_for(rest,"full")]
    Xg=[x for x,_ in rows_for(plat,"full")]; yg=[t for _,t in rows_for(plat,"full")]
    w,b=train(Xt,yt)
    print(f"  留出 Platonic 族（{len(Xg)} 条 unseen：A4/O/Oh/I/Ih × orig/del）泛化 acc = {bucket_acc(w,b,Xg,yg):.2f}")
    # 逐个给出预测，看得见
    names=[r["name"]+"/"+r["variant"] for r in plat]
    for nm,x,yi in zip(names,Xg,yg):
        p=sigmoid(sum(wi*xv for wi,xv in zip(w,x))+b)
        print(f"      {nm:18s} 真值={yi} 预测={p:.2f}")

if __name__=="__main__": main()
