#!/usr/bin/env python3
"""v18：大规模数据生成（用户：'增加大规模数据微调'，数学库在 /data/work/discrete-mathematics）。

蓝本（本批）：Dihedral n=3..33 ×5 + Cyclic n=3..60 ×3 + Z乘积 n,m∈2..9(order≤40) ×5
≈ 459 条（现有 199 → 2.3x）。标签全部符号层（TC + 定理）判定。
后续扩展（库新族，需族模板工程）：Q8（BinaryTetrahedral.agda，演示耦合需精确建模）、
  C4/C12 库 FinGroup 实例、A4/GL2(2,2) 表示论族。
"""
import json, math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train_causal_v13 import gen_dihedral, gen_cyclic
from todd_coxeter import enume_group

def gen_zprod_large(n, m):
    order=n*m
    k1=next((x for x in range(2,order+1) if math.gcd(x,order)==1),1)
    rels=[["R_gen",n,n],["R_gen",m,m],["R_commX",1,0],["R_gen_red",k1,order]]
    out=[]
    for variant,mask,ngen,yo,ya in [
        ("orig",[],order,0,0),("del-gen0",[0],order,1,0),("del-gen1",[1],order,1,0),
        ("del-comm1",[2],1,1,1),("del-redundant",[3],order,0,0)]:
        out.append({"name":f"Z{n}xZ{m}","order":order,"abelian":True,"family":"Zprod",
                    "relations":rels,"relations_masked":mask,"variant":variant,
                    "y_order":yo,"y_abelian":ya,"new_gen_order":ngen})
    return out

def main():
    here=os.path.dirname(os.path.abspath(__file__))
    recs=json.load(open(os.path.join(here,"group_dataset_rel_v17.json")))
    base=len(recs)
    # 1) Dihedral 扩展 n=19..33（v17 已到 17）
    have_dh={r["order"]//2 for r in recs if r["family"]=="Dihedral"}
    for n in range(19,34):
        if n not in have_dh: recs+=gen_dihedral(n)
    # 2) Cyclic 扩展 n=20..60（v17 到 19）
    have_cy={r["order"] for r in recs if r["family"]=="Cyclic"}
    for n in range(20,61):
        if n not in have_cy: recs+=gen_cyclic(n)
    # 3) Z 乘积扩展 n,m∈2..9
    have_z={(r["order"],) for r in recs if r["family"]=="Zprod" and r["variant"]=="orig"}
    for n in range(2,10):
        for m in range(n,10):
            if n*m<=40 and (n*m,) not in {(r["order"],) for r in recs if r["family"]=="Zprod" and r["variant"]=="orig"} :
                recs+=gen_zprod_large(n,m)
    out=os.path.join(here,"group_dataset_rel_v18.json")
    json.dump(recs, open(out,"w"), indent=1, ensure_ascii=False)
    from collections import Counter
    comp=Counter((r["y_order"]+r["y_abelian"])/2 for r in recs)
    fam=Counter(r["family"] for r in recs)
    print(f"v18 数据: {base} → {len(recs)} 条（+{len(recs)-base}）")
    print(f"  族: {dict(fam)}")
    print(f"  复合标签: {dict(sorted(comp.items()))}")

if __name__=="__main__": main()
