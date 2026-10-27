#!/usr/bin/env python3
"""v16：Z 乘积族扩充 1.0 类——abelian 维度学稳（自建模型独立可训，无外部依赖）。

用户方向（j-mu6f4tgp 后续）：神经网络应自建、内在、不依赖外部 LLM；当前先把模型训练好。
K4=GF2×GF2 用 Z 乘积展示 ⟨a,b|aⁿ,bᵐ,[a,b]⟩ 时 TC 全可算（无需 Agda）：
  - del-comm（删 [a,b]）→ 自由积 C_n*C_m（无限、非阿贝尔）→ (1,1) = 1.0 类
  - del-gen0（删 aⁿ）→ Z×C_m（阿贝尔无限）→ (1,0)
  - del-red（删冗余）→ 不变 (0,0)
本版：批量 Zn×Zm（n,m∈{2,3,4,5}，order≤25）扩充 1.0 类，三值模型重训。
验收：1.0 类泛化（留出 Z 乘积族的 del-comm）从 v15 的 0.50 提升。
"""
import json, math, random, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train_causal_v15 import train3, predict3

def gen_zprod(n, m):
    """Zn×Zm 族：⟨aⁿ,bᵐ,[a,b]⟩ 阿贝尔 order=n*m。变体标签（TC 已验）：
    del-comm1 删 [a,b] → 自由积 → (1,1)；del-gen0 删 aⁿ → Z×Cm 阿贝尔无限 → (1,0)；
    del-gen1 删 bᵐ → Cn×Z 阿贝尔无限 → (1,0)；del-red → (0,0)；orig → (0,0)。
    """
    order=n*m
    k1=next((x for x in range(2,order+1) if math.gcd(x,order)==1),1)
    rels=[["R_gen",n,n],["R_gen",m,m],["R_comm",0,0],["R_gen_red",k1,order]]
    out=[]
    for variant,mask,ngen,yo,ya in [
        ("orig",[],order,0,0),
        ("del-gen0",[0],order,1,0),
        ("del-gen1",[1],order,1,0),
        ("del-comm1",[2],1,1,1),
        ("del-redundant",[3],order,0,0)]:
        out.append({"name":f"Z{n}xZ{m}","order":order,"abelian":True,"family":"Zprod",
                    "relations":rels,"relations_masked":mask,"variant":variant,
                    "y_order":yo,"y_abelian":ya,"new_gen_order":ngen})
    return out

def main():
    here=os.path.dirname(os.path.abspath(__file__))
    recs=json.load(open(os.path.join(here,"group_dataset_rel_v15.json")))
    base=len(recs)
    for (n,m) in [(2,2),(2,3),(3,3),(2,4),(2,5),(3,4),(4,4),(3,5),(2,7),(4,5)]:
        if n*m<=25: recs += gen_zprod(n,m)
    out=os.path.join(here,"group_dataset_rel_v16.json")
    json.dump(recs, open(out,"w"), indent=1, ensure_ascii=False)
    from collections import Counter
    comp=Counter((r["y_order"]+r["y_abelian"])/2 for r in recs)
    fam=Counter(r["family"] for r in recs)
    print(f"v16 数据: {base} → {len(recs)} 条（+{len(recs)-base} Z 乘积）")
    print(f"  复合标签: {dict(sorted(comp.items()))}（1.0 类: {comp.get(1.0,0)} 条）")
    print(f"  族: {dict(fam)}")

    # 三值模型：全量训练 + 留出 Z 乘积族
    rel_types=sorted({rt for r in recs for rt,_,_ in r["relations"]})
    def rows(sub): return [(featurize16(r,rel_types),(r["y_order"]+r["y_abelian"])/2.0) for r in sub]
    X=[x for x,_ in rows(recs)]; y=[t for _,t in rows(recs)]
    W,B=train3(X,y)
    acc=sum(1 for x,v in zip(X,y) if predict3(W,B,x)[0]==v)/len(X)
    print(f"  三值训练 acc = {acc:.2f}")
    # 留出 Zprod
    zp=[r for r in recs if r["family"]=="Zprod"]; rest=[r for r in recs if r["family"]!="Zprod"]
    Xt=[x for x,_ in rows(rest)]; yt=[t for _,t in rows(rest)]
    Xg=[x for x,_ in rows(zp)]; yg=[t for _,t in rows(zp)]
    W2,B2=train3(Xt,yt)
    ag=sum(1 for x,v in zip(Xg,yg) if predict3(W2,B2,x)[0]==v)/len(Xg)
    print(f"  留出 Z 乘积族（{len(Xg)} unseen，含 {sum(1 for v in yg if v==1.0)} 条 1.0 类）泛化 acc = {ag:.2f}")
    # 1.0 类专项：del-comm1 预测
    n1=0; ok1=0
    for r,x,v in zip(zp,Xg,yg):
        if v==1.0:
            n1+=1
            pv,_=predict3(W2,B2,x)
            if pv==1.0: ok1+=1
    print(f"  1.0 类专项: {ok1}/{n1} 判对" if n1 else "  无 1.0 类样本")

def featurize16(r, rel_types):
    from train_causal_v9 import featurize
    return featurize(r, rel_types)

if __name__=="__main__": main()
