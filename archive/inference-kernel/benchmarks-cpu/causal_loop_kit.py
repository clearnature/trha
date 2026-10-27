#!/usr/bin/env python3
"""causal_loop_kit：自建因果模型「神经提议→符号验证」一键闭环（接线联调）。

把三构件接到一起：
  1. 神经提议：CLI（trha_causal_verdict.py，权重 model_causal_v19.json）
     输入关系描述 → 三值因果提议 (0/0.5/1.0)
  2. 符号裁决：TC + 代换定理（todd_coxeter.py / reconcile build）
     独立重算 Δorder → 真值
  3. 三铁律闭合：一致 = PASS；不一致 = WARN（标注不拒绝，照 ConstraintVerdict 语义）

用法：python3 causal_loop_kit.py
输出：逐条 PASS/WARN + 汇总。这证明「自建模型提议、符号层裁决」在仓库内可直接运行。
"""
import json, math, os, sys, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from reconcile_v9_labels import build
from todd_coxeter import enume_group

HERE=os.path.dirname(os.path.abspath(__file__))
CASES=[
  # (名称, relations, masked, order, ngen, 预期)
  ("D6 del-comm（非阿贝尔）", [["R_gen",6,6],["R_gen",2,2],["R_comm",0,0],["R_gen_red",5,12]],[2],12,1),
  ("Z2xZ2 del-comm（阿贝尔）", [["R_gen",2,2],["R_gen",2,2],["R_commX",1,0],["R_gen_red",3,4]],[2],4,1),
  ("C17 del-gen", [["R_gen",17,17],["R_gen_red",1,17]],[0],17,17),
  ("D38 del-gen0（越界）", [["R_gen",19,19],["R_gen",2,2],["R_comm",0,0],["R_gen_red",3,38]],[0],38,38),
  ("Z3xZ4 orig", [["R_gen",3,3],["R_gen",4,4],["R_commX",1,0],["R_gen_red",5,12]],[],12,12),
  ("A4 del-comm", [["R_gen",3,3],["R_gen",2,2],["R_comm",0,0],["R_gen_red",5,12]],[2],12,1),
]

def tc_order(relations, masked):
    """通用 TC 裁决（族无关）：关系集 → (gens, words)。
    R_gen/rm 生成元；R_comm=反交换词（Dihedral 型 s·r·s·r⁻¹，用前两生成元）；
    R_commX=交换词（Zprod 型 [g1,g2]）；masked 的生成元阶→0（自由）。"""
    gens=[]; rgen_idx=[]
    for i,(rt,p,o) in enumerate(relations):
        if rt=="R_gen":
            gens.append((f"g{i}", 0 if i in masked else o)); rgen_idx.append(i)
        # R_gen_red = 冗余 relator（v9 语义）：不建独立生成元——它不改变群演示
        # （符号层在 del-redundant 的同构硬判里已经处理它的删除=不变）
    words=[]
    if len(gens)>=2:
        if any(rt=="R_comm" and i not in masked for i,(rt,_,_) in enumerate(relations)):
            words.append((2,1,2,-1))          # s·r·s·r⁻¹
        if any(rt=="R_commX" and i not in masked for i,(rt,_,_) in enumerate(relations)):
            words.append((1,2,-1,-2))         # g1·g2·g1⁻¹·g2⁻¹
    return gens, words

def symbol_verdict(relations, masked, order, ngen=None):
    """符号层独立裁决（TC+定理）：(Δorder, Δabelian) 复合三值，与神经三值对齐。

    Δorder：删前/删后 TC 阶比较（变含 ∞）。
    Δabelian（定理）：删 comm 型关系时——
        R_commX（交换型）：原阿贝尔（Z 乘积/K4 定义如此）→ 删后自由积非阿贝尔 ⟹ 变 1
        R_comm（反交换型）：原非阿贝尔（D/Platonic 定义）→ 删后自由积仍非阿贝尔 ⟹ 不变 0
      del-gen：不变（自由积保持非阿贝尔性质或 Z 乘积保持阿贝尔）⟹ 0
    """
    g0,w0=tc_order(relations,set()); g1,w1=tc_order(relations,set(masked))
    k0=enume_group(g0,w0); k1=enume_group(g1,w1)
    d_order=(k0 is None)!=(k1 is None) or (k0 is not None and k1 is not None and k0!=k1)
    commX=[i for i,(rt,_,_) in enumerate(relations) if rt=="R_commX"]
    comm=[i for i,(rt,_,_) in enumerate(relations) if rt=="R_comm"]
    del_commX = any(i in masked for i in commX)
    del_comm  = any(i in masked for i in comm)
    # 原群阿贝尔性（定理）：R_commX=交换型 → 原群阿贝尔；R_comm=反交换型 → 原群非阿贝尔
    orig_abelian = 1 if commX else 0
    del_any_comm = del_commX or del_comm
    # abelian 变化 = 删 comm 且 原阿贝尔 → 自由积非阿贝尔（变 1）；原非阿贝尔删 comm 仍非阿贝尔（变 0）
    d_abelian = 1 if (del_any_comm and orig_abelian) else 0
    return (1 if d_order else 0, d_abelian), f"{k0 or '∞'}→{k1 or '∞'}"

def neural_verdict(relations, masked, order, ngen):
    rels=json.dumps(relations); ms=json.dumps(masked)
    r=subprocess.run(["python3",os.path.join(HERE,"trha_causal_verdict.py"),
                      "--relations",rels,"--masked",ms,"--order",str(order),
                      "--new-gen-order",str(ngen)],
                     capture_output=True,text=True,timeout=30)
    for l in r.stdout.splitlines():
        if "神经提议" in l:
            return float(l.split(": ")[1].split("  ")[0])
    raise RuntimeError("CLI 无输出: "+r.stderr)

def main():
    print("=== 自建因果模型闭环：神经提议 × 符号验证（三铁律）===")
    npass=nwarn=0
    for nm,rels,masked,order,ngen in CASES:
        try:
            neural=neural_verdict(rels,masked,order,ngen)
            (do,da),basis=symbol_verdict(rels,masked,order)
            symbol=(do+da)/2.0
            agree=(neural==symbol)
            tag="PASS" if agree else "WARN"
            if agree: npass+=1
            else: nwarn+=1
            print(f"  [{tag}] {nm:24s} 神经={neural} 符号=({do},{da}) 复合={symbol}（{basis}）")
        except Exception as e:
            print(f"  [ERR] {nm:24s} {e}")
            nwarn+=1
    print(f"\n汇总: PASS={npass} WARN={nwarn}（WARN=标注不拒绝；0 WARN=神经与符号完全一致）")
    return 0 if nwarn==0 else 1

if __name__=="__main__": sys.exit(main())
