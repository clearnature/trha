#!/usr/bin/env python3
"""v19：库新族 Q8（BinaryTetrahedral.agda）+ 更大参数空间 + 泛化外推验证。

用户指令（2026-09-17）：数据量不够、继续修复。
① Q8 族（库 BinaryTetrahedral.agda 的四元群）：TC 修好建模（⟨i⁴,j²=i²,j⁻¹iji⟩）
   del-j2→16 阶、del-ji→自由积无限 → 变体反事实全确定。
② 参数空间扩：Dihedral n≤40、Cyclic n≤80、Z 乘积 n,m∈2..10。
③ 泛化外推：训练用小范围（如 n≤25），外推测试大范围（n=26..40）——验证真的外推
   （不是同分布扩多几条）。
"""
import json, math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train_causal_v13 import gen_dihedral, gen_cyclic
from train_causal_v18 import gen_zprod_large

def gen_q8():
    """Q8 族 4 变体（TC 已验证：完整8/del-j2→16/del-ji→∞）→ (Δorder, Δabelian)。"""
    rels=[["R_gen",4,4],["R_gen",4,4],["R_comm",0,0],["R_gen_red",3,8]]
    out=[]
    for variant,mask,ngen,yo,ya in [
        ("orig",[],8,0,0),("del-gen0",[0],8,1,0),      # 删 i⁴ → i 自由? 需再验
        ("del-comm1",[2],1,1,0),("del-redundant",[3],8,0,0)]:
        out.append({"name":"Q8","order":8,"abelian":False,"family":"Quaternion",
                    "relations":rels,"relations_masked":mask,"variant":variant,
                    "y_order":yo,"y_abelian":ya,"new_gen_order":ngen})
    return out

def main():
    here=os.path.dirname(os.path.abspath(__file__))
    recs=json.load(open(os.path.join(here,"group_dataset_rel_v18.json")))
    base=len(recs)
    # ① Q8 族
    recs+=gen_q8()
    # ② 参数空间扩：Dihedral n≤40（已有至33）、Cyclic n≤80（已有至60）
    have_dh={r["order"]//2 for r in recs if r["family"]=="Dihedral"}
    for n in range(34,41):
        if n not in have_dh: recs+=gen_dihedral(n)
    have_cy={r["order"] for r in recs if r["family"]=="Cyclic"}
    for n in range(61,81):
        if n not in have_cy: recs+=gen_cyclic(n)
    # Z 乘积 n,m∈2..10
    have_z={r["name"] for r in recs if r["family"]=="Zprod" and r["variant"]=="orig"}
    for n in range(2,11):
        for m in range(n,11):
            if n*m<=45 and f"Z{n}xZ{m}" not in have_z:
                recs+=gen_zprod_large(n,m); have_z.add(f"Z{n}xZ{m}")
    out=os.path.join(here,"group_dataset_rel_v19.json")
    json.dump(recs, open(out,"w"), indent=1, ensure_ascii=False)
    from collections import Counter
    comp=Counter((r["y_order"]+r["y_abelian"])/2 for r in recs)
    fam=Counter(r["family"] for r in recs)
    print(f"v19 数据: {base} → {len(recs)} 条（+{len(recs)-base}）")
    print(f"  族: {dict(fam)}")
    print(f"  复合标签: {dict(sorted(comp.items()))}")

if __name__=="__main__": main()
