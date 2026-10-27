#!/usr/bin/env python3
"""v17：图传播（GCN/结构层相位对齐假设检验）在 159 条三值数据上重测。

背景（j-mu6fmdel-pmio 教训 + j-mu6fl1z4-yf1y 决策）：用户理论「训练=相位对齐」
的正确落点在结构传播层（adj/prop = 变量间 GF3 相位对齐），不是特征 hack。
本版：TinyGCN 适配 R_commX 类型 + 三值标签，检验图传播是否在 1.0 类判别上优于
线性（v16 交叉特征训练内 0.994、留出 1.0 类 7/10）。
"""
import json, math, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, torch, torch.nn as nn
from train_causal_v10 import TinyGCN, adjacency

def build_graph_x(r):
    """v10 build_graph + R_commX（交换 comm → 类型 3）。"""
    masked=set(r["relations_masked"])
    nodes=[]
    for i,(rt,p,o) in enumerate(r["relations"]):
        if i in masked: continue
        t={"R_gen":0,"R_comm":1,"R_gen_red":2,"R_commX":3}[rt]
        nodes.append([t, math.log(p+1)/3.0, math.log(o+1)/5.0, 1.0])
    if not nodes: nodes.append([-1,0.0,0.0,0.0])
    return nodes

FEAT=6
def pack(subset):
    xs,As,ms=[],[],[]
    for r in subset:
        nodes=build_graph_x(r); n=len(nodes)
        x=np.zeros((n,FEAT))
        for i,nd in enumerate(nodes):
            if nd[0]>=0:
                x[i,nd[0]]=1.0; x[i,3]=nd[1]; x[i,4]=nd[2]; x[i,5]=nd[3]
        xs.append(torch.tensor(x,dtype=torch.float32))
        As.append(torch.tensor(adjacency(n),dtype=torch.float32))
        ms.append(torch.ones(n))
    return xs,As,ms

def run(subset, epochs=500, seed=0):
    torch.manual_seed(seed); np.random.seed(seed)
    xs,As,ms=pack(subset)
    lab=torch.tensor([(r["y_order"]+r["y_abelian"])/2.0 for r in subset],dtype=torch.float32)
    m=TinyGCN(FEAT); opt=torch.optim.Adam(m.parameters(),lr=0.05)
    lossf=nn.MSELoss()
    for _ in range(epochs):
        opt.zero_grad(); out=m(xs,As,ms); loss=lossf(out,lab); loss.backward(); opt.step()
    return m

bucket=lambda p: 0 if p<0.25 else 1 if p<0.75 else 2

def main():
    recs=json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),"group_dataset_rel_v16.json")))
    from collections import Counter
    comp=Counter((r["y_order"]+r["y_abelian"])/2 for r in recs)
    print(f"=== v17 GCN · {len(recs)} 条 · 复合 {dict(sorted(comp.items()))} ===")
    # 全量训练
    m=run(recs)
    xs,As,ms=pack(recs)
    with torch.no_grad(): out=m(xs,As,ms).numpy()
    labels=[(r["y_order"]+r["y_abelian"])/2.0 for r in recs]
    tr=sum(1 for o,v in zip(out,labels) if bucket(o)==bucket(v))/len(recs)
    print(f"  GCN 训练 acc = {tr:.2f}")
    # 留出 Z 乘积族（结构与 v16 线性对照）
    for fam in ("Zprod","Gf2x"):
        hold=[r for r in recs if r["family"]==fam]; rest=[r for r in recs if r["family"]!=fam]
        if not hold: continue
        m2=run(rest)
        xs,As,ms=pack(hold)
        with torch.no_grad(): outg=m2(xs,As,ms).numpy()
        hl=[(r["y_order"]+r["y_abelian"])/2.0 for r in hold]
        ag=sum(1 for o,v in zip(outg,hl) if bucket(o)==bucket(v))/len(hold)
        n1=ok=0
        for r,o,v in zip(hold,outg,hl):
            if v==1.0:
                n1+=1
                if bucket(o)==2: ok+=1
        print(f"  留出 {fam:5s}（{len(hold)}）泛化 {ag:.2f}，1.0 类 {ok}/{n1}")

if __name__=="__main__": main()
