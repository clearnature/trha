#!/usr/bin/env python3
"""v13：符号层自动生成扩展数据 + 大规模泛化检验。

背景（用户警告）：v9 的 68 条泛化是「小规模未见群」，若扩到 ~150 条可能露问题。
本版：用符号层（TC+代换定理，todd_coxeter.py）为**新群**自动生成反事实标签——
  Dihedral D9/D11/D13/D15/D17、循环 C14/C15/C17/C19、GF 交叉 ——
  各 5 变体（orig/del-gen0/del-gen1/del-comm1/del-redundant），遵守 v9 规范（含 R_gen_red）。
验证：并入后神经模型（v9 线性）五族留出泛化是否仍 ~1.00；acc 掉 ⇨ 小规模通过的假象被揭穿。
"""
import json, math, random, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from todd_coxeter import enume_group

def gen_dihedral(n):
    """D_2n：relations 按 v9 规范 [R_gen(n), R_gen(2), R_comm, R_gen_red(k=h, order=2n)]。
    k = 与 n 互质的数（v9 里用 gcd(k,order)=1）。
    标签（符号层定理）：del-gen0(删 rⁿ)→D_∞ 无限 Δ=1；del-gen1(删 s²)→自由积 Δ=1；
      del-comm(删 srs)→自由积 Δ=1；del-red→不变 Δ=0；orig→Δ=0。abelian 均不变 0。
    """
    k=next((x for x in range(2,n) if math.gcd(x,2*n)==1), 1)
    rels=[["R_gen",n,n],["R_gen",2,2],["R_comm",0,0],["R_gen_red",k,2*n]]
    out=[]
    for variant,mask,ngen in [("orig",[],2*n),("del-gen0",[0],2*n),
                              ("del-gen1",[1],2*n),("del-comm1",[2],1),("del-redundant",[3],2*n)]:
        dord=1 if variant in ("del-gen0","del-gen1","del-comm1") else 0
        out.append({"name":f"D{2*n}","order":2*n,"abelian":False,"family":"Dihedral",
                    "relations":rels,"relations_masked":mask,"variant":variant,
                    "y_order":dord,"y_abelian":0,"new_gen_order":ngen})
    return out

def gen_cyclic(n):
    """C_n：单生成元。del-gen0 删 aⁿ → 群自由（无限）Δ=1；del-red 不变。
    规范含 R_gen_red(k, n)。"""
    k=next((x for x in range(2,n) if math.gcd(x,n)==1), 1)
    rels=[["R_gen",n,n],["R_gen_red",k,n]]
    out=[]
    for variant,mask,ngen in [("orig",[],n),("del-gen0",[0],n),("del-red",[1],n)]:
        dord=1 if variant=="del-gen0" else 0
        out.append({"name":f"C{n}","order":n,"abelian":True,"family":"Cyclic",
                    "relations":rels,"relations_masked":mask,"variant":variant,
                    "y_order":dord,"y_abelian":0,"new_gen_order":ngen})
    return out

def main():
    recs=json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),"group_dataset_rel_v9.json")))
    base=len(recs)
    for n in (9,11,13,15,17):
        recs += gen_dihedral(n)
    for n in (14,15,17,19):
        recs += gen_cyclic(n)
    out=os.path.join(os.path.dirname(os.path.abspath(__file__)),"group_dataset_rel_v13.json")
    json.dump(recs, open(out,"w"), indent=1, ensure_ascii=False)
    from collections import Counter
    print(f"v13 数据集: {base} → {len(recs)} 条（+{len(recs)-base} 符号层生成）")
    print("  标签分布:", dict(sorted(Counter((r['y_order'],r['y_abelian']) for r in recs).items())))
    print("  族分布:", dict(Counter(r['family'] for r in recs)))

    # 符号层对账新增部分（TC 重算 Δorder vs 生成器标签）
    from reconcile_v9_labels import build
    mism=0
    for r in recs:
        if r["variant"]=="orig" or r["variant"]=="del-redundant": continue
        g0,w0=build(r,False); g1,w1=build(r,True)
        k0=enume_group(g0,w0); k1=enume_group(g1,w1)
        changed=(k0 is None)!=(k1 is None) or (k0 is not None and k1 is not None and k0!=k1)
        if changed != (r["y_order"]==1): mism+=1
    print(f"  新增 del 行符号对账不一致: {mism}")

if __name__=="__main__": main()
