#!/usr/bin/env python3
"""v6 双结论验收：阶变 + 阿贝尔变，各跨未见群泛化（修正语义后）。"""
import json, math, random

def featurize(r, rel_types, task):
    dim = len(rel_types)*4
    bag=[0.0]*dim
    masked=set(r["relations_masked"])
    for i,(rt,p,_) in enumerate(r["relations"]):
        if i in masked: continue
        t=rel_types.index(rt); b=min(3,int(math.log(p+1)/1.5))
        bag[t*4+b]+=1.0
    is_del = 1.0 if r["relations_masked"] else 0.0
    if task=="abelian":
        del_comm = 1.0 if any(rt=="R_comm" and i in masked for i,(rt,_,_) in enumerate(r["relations"])) else 0.0
        return bag+[math.log(r["order"]+1)/5.0, is_del, del_comm, 1.0 if r["abelian"] else 0.0]
    return bag+[math.log(r["order"]+1)/5.0, math.log(r["new_gen_order"]+1)/5.0, is_del]

def sigmoid(z): return 1.0/(1.0+math.exp(-z))
def train(X,y,epochs=4000,lr=0.3,seed=11):
    n,d=len(X),len(X[0]); rng=random.Random(seed)
    w=[rng.uniform(-0.2,0.2) for _ in range(d)]; b=0.0
    for _ in range(epochs):
        gw=[0.0]*d; gb=0.0
        for xi,yi in zip(X,y):
            p=sigmoid(sum(wi*xv for wi,xv in zip(w,xi))+b); err=p-yi
            for k in range(d): gw[k]+=err*xi[k]
            gb+=err
        for k in range(d): w[k]-=lr*gw[k]/n
        b-=lr*gb/n
    return w,b

def acc_of(model, X, y):
    w,b = model
    return sum(1 for xi,yy in zip(X,y) if (sigmoid(sum(wi*xv for wi,xv in zip(w,xi))+b)>0.5)==(yy>0.5))/len(X)

def main():
    recs=json.load(open("benchmarks/cpu/group_dataset_rel.json"))
    rel_types=sorted({rt for r in recs for rt,_,_ in r["relations"]})
    Xo=[featurize(r,rel_types,"order") for r in recs]; yo=[1.0 if r["y_order"]==1 else 0.0 for r in recs]
    Xa=[featurize(r,rel_types,"abelian") for r in recs]; ya=[1.0 if r["y_abelian"]==1 else 0.0 for r in recs]
    mo=train(Xo,yo,seed=7); ma=train(Xa,ya,seed=11)
    print(f"=== v6 双结论验收 · {len(recs)} 条 ===")
    print(f"  阶变 训练 acc = {acc_of(mo,Xo,yo):.2f}")
    print(f"  阿贝尔变 训练 acc = {acc_of(ma,Xa,ya):.2f}")
    tests_o=[
      {"name":"D7","order":14,"relations":[("R_gen",7,7),("R_gen",2,2),("R_comm",0,0)],"relations_masked":[0],"y_order":1,"new_gen_order":3},
      {"name":"D9","order":18,"relations":[("R_gen",9,9),("R_gen",2,2),("R_comm",0,0)],"relations_masked":[0],"y_order":1,"new_gen_order":4},
      {"name":"D7full","order":14,"relations":[("R_gen",7,7),("R_gen",2,2),("R_comm",0,0)],"relations_masked":[],"y_order":0,"new_gen_order":14},
    ]
    tests_a=[
      {"name":"C12delcomm","order":12,"abelian":True,"relations":[("R_gen",12,12),("R_comm",0,0)],"relations_masked":[1],"y_abelian":1},
      {"name":"D10full","order":20,"abelian":False,"relations":[("R_gen",10,10),("R_gen",2,2),("R_comm",0,0)],"relations_masked":[],"y_abelian":0},
      {"name":"Alt5full","order":60,"abelian":False,"relations":[("R_gen",5,5),("R_gen",3,3),("R_comm",0,0)],"relations_masked":[],"y_abelian":0},
    ]
    ok=0
    for t in tests_o:
        x=featurize(t,rel_types,"order"); p=sigmoid(sum(wi*xv for wi,xv in zip(mo[0],x))+mo[1])>0.5
        exp=t["y_order"]>0; ok+=(p==exp)
        print(f"  阶变泛化 {t['name']}: {int(p)}/{t['y_order']} {'✓' if p==exp else '✗'}")
    for t in tests_a:
        x=featurize(t,rel_types,"abelian"); p=sigmoid(sum(wi*xv for wi,xv in zip(ma[0],x))+ma[1])>0.5
        exp=t["y_abelian"]>0; ok+=(p==exp)
        print(f"  阿贝尔泛化 {t['name']}: {int(p)}/{t['y_abelian']} {'✓' if p==exp else '✗'}")
    print(f"双结论未见泛化合计：{ok}/{len(tests_o)+len(tests_a)}")

if __name__=="__main__": main()
