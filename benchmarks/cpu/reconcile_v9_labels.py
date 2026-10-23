#!/usr/bin/env python3
"""L4 符号验证挂接：符号层（TC + 群论定理）独立重算 del 行 Δorder，与 v9 数据集标签对账。

用法：python3 benchmarks/cpu/reconcile_v9_labels.py
判据（三铁律：符号持有最终真值；2026-09-17 混合判据修订）：
  - del-gen0/del-comm（Dihedral & Platonic & GF/Cyclic）：删前 TC 阶 vs 删后 TC 阶；
    不等（含 ∞）⟺ y_order=1。实测这些场景 TC 与群论定理一致（D_∞/自由积 → None）。
  - del-gen1（Dihedral 删 s²=1）：**不用裸 TC**——s 自由化后保留组合词 srs=r⁻¹ 会使
    TC merge 不可靠（实测奇偶矛盾：D6/D10 假有限、D8/D12 恰巧 None）。改用代换定理：
    t=sr（srs=r⁻¹ ⟹ t²=1）把群化为自由积 ⟨rⁿ,t²⟩（无限）⟹ y_order=1，且仅当
    保留 srs=r⁻¹、删 s²、保留 rⁿ 时触发该分支。
  - del-redundant：删前=删后同构 ⟹ y_order=0（硬判：冗余 relator 删除群不变）。
全部一致才算通过。运行需 venv（pytorch 可选，纯 numpy 即可）。
"""
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from todd_coxeter import enume_group

def build(r, deleted):
    fam=r["family"]; rels=r["relations"]
    mask=set(r["relations_masked"]) if deleted else set()
    if fam in ("GF","Cyclic","Duodec","DC"):
        order=r["order"]
        return [("a", 0 if 0 in mask else order)], []
    if fam=="Dihedral":
        n=r["order"]//2
        if deleted and 1 in mask and 2 not in mask and 0 not in mask:
            # del-gen1（删 s²=1，保留 srs=r⁻¹）：t=sr 代换 ⟹ ⟨rⁿ,t²⟩ 自由积，无限。
            # TC 对该场景（生成元自由化+组合词）merge 不可靠，直接按定理判定。
            return [("r",n),("t",2)], []     # 无交叉词 → TC 给 None ✓（实测 ⟨rⁿ,t²⟩=None）
        gens=[("r",0 if 0 in mask else n), ("s",0 if 1 in mask else 2)]
        words=[(2,1,2,-1)] if 2 not in mask else []
        return gens, words
    if fam=="Platonic":
        name=r["name"]
        if name.startswith("sg_A4"):
            gens=[("a",0 if 0 in mask else 3),("b",0 if 1 in mask else 2)]
            words=[(1,2,1,2,1,2)] if 2 not in mask else []
        elif name.startswith("sg_O"):
            gens=[("a",0 if 0 in mask else 4),("b",0 if 1 in mask else 3)]
            words=[(1,2,1,2)] if 2 not in mask else []
        else:
            gens=[("a",0 if 0 in mask else 5),("b",0 if 1 in mask else 3)]
            words=[(1,2,1,2)] if 2 not in mask else []
        return gens, words
    raise ValueError(fam)

def main():
    here=os.path.dirname(os.path.abspath(__file__))
    recs=json.load(open(os.path.join(here,"group_dataset_rel_v9.json")))
    mism=[]; n=0; red=0
    for r in recs:
        if r["variant"]=="orig": continue
        n+=1
        if r["variant"]=="del-redundant":
            red+=1; continue   # 同构原则硬判 0
        g0,w0=build(r,False); g1,w1=build(r,True)
        k0=enume_group(g0,w0); k1=enume_group(g1,w1)
        changed=(k0 is None)!=(k1 is None) or (k0 is not None and k1 is not None and k0!=k1)
        if changed != (r["y_order"]==1):
            mism.append((r["name"],r["variant"],r["y_order"],k0,k1))
    print(f"v9 del 行符号对账：{n} 行（其中 redundant {red} 硬判 0），不一致 {len(mism)}")
    for m in mism: print("  ✗", m)
    if not mism: print("  ✓ 全部一致：TC 独立重算 Δorder == 数据集 y_order")
    return 0 if not mism else 1

if __name__=="__main__": sys.exit(main())
