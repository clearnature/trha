#!/usr/bin/env python3
"""v12：在线符号裁决器 —— 神经提议 × 符号验证闭环（数据侧）。

三铁律落实：
  1. AI 只提议从不裁决 → v9 线性模型输出 prob（提议方）
  2. 裁决必须独立可重放 → 符号层 = TC + 代换定理（混合判据，reconcile_v9_labels.build）
  3. 符号胜、标注不拒绝 → 分歧时记录 Warn（仍给神经预测，标注符号真值）

流程：
  a) 训练 v9 模型（68 条，同 train_causal_v9.py，seed=7 稳健参数）
  b) 对「训练未见过的真实群」（D7/D9/C11/D7full/Alt5full 等，v5/v6 时代的 unseen 集）
     逐条: 神经提议 bucket vs 符号裁决真值 → Pass/Warn 表
  c) 对决断言：符号裁决 = 混合判据（TC 或定理）独立算出，绝不使用数据集标签

unseen 样本的关系集与标签由符号层现场构造（不取自任何训练文件），
所以「标签正确性」本身也被符号层证明——这是裁决闭环的完整性所在。
"""
import json, sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from reconcile_v9_labels import build   # 复用混合判据的演示→TC 映射
from todd_coxeter import enume_group
from train_causal_v9 import featurize, train, pred, bucket

class R:  # 轻量记录：build 用属性访问，featurize 用下标访问，两套都支持
    def __init__(s, rels, masked, fam, order, ngen=None):
        s.relations=rels; s.relations_masked=masked; s.family=fam; s.order=order
        s.y_order=0; s.y_abelian=0
        # v9 数据语义（2026-09-17 核实）：del-gen0/del-redundant 的 new_gen_order=原群阶；
        # del-comm1 的 =1（生成元阶概念失效，TC 修的 Dihedral）。orig=原群阶。
        s.new_gen_order = ngen if ngen is not None else (order if not masked else 1)
    def __getitem__(s, k):
        return {"relations":s.relations,"relations_masked":s.relations_masked,
                "family":s.family,"order":s.order,"new_gen_order":s.new_gen_order,
                "y_order":s.y_order,"y_abelian":s.y_abelian}[k]

def symbol_verdict(rels, masked, fam, order):
    """符号层独立裁决：删前后 TC 阶比较（含代换定理分支，build 已处理）。返回 (Δorder, 依据)。"""
    r=R(rels, masked, fam, order)
    g0,w0=build(r, False); g1,w1=build(r, True)
    k0=enume_group(g0,w0); k1=enume_group(g1,w1)
    changed=(k0 is None)!=(k1 is None) or (k0 is not None and k1 is not None and k0!=k1)
    basis=f"TC: 删前={k0 or '∞'} 删后={k1 or '∞'}"
    return (1 if changed else 0), basis

def make_unseen():
    """训练未见过、且符号层可独立裁决的真实群样本（关系集手工构造，标签由符号层给）。"""
    S=[]
    # D7 = ⟨r⁷,s²,srs=r⁻¹⟩（order 14，非循环 unseen）；按 v9 规范补 R_gen_red(互质k,群阶)
    D7=[["R_gen",7,7],["R_gen",2,2],["R_comm",0,0],["R_gen_red",3,14]]
    S += [("D7/orig", D7, [], "Dihedral", 14, 14),
          ("D7/del-gen0(删r⁷)", D7, [0], "Dihedral", 14, 14),
          ("D7/del-gen1(删s²)", D7, [1], "Dihedral", 14, 14),
          ("D7/del-comm(删srs)", D7, [2], "Dihedral", 14, 1),
          ("D7/del-red", D7, [3], "Dihedral", 14, 14)]
    # D9 = ⟨r⁹,s²,srs=r⁻¹⟩（order 18）
    D9=[["R_gen",9,9],["R_gen",2,2],["R_comm",0,0],["R_gen_red",5,18]]
    S += [("D9/orig", D9, [], "Dihedral", 18, 18),
          ("D9/del-comm", D9, [2], "Dihedral", 18, 1)]
    # C11 = 循环群（order 11，素阶 unseen cyclic）
    C11=[["R_gen",11,11],["R_gen_red",2,11]]
    S += [("C11/orig", C11, [], "Cyclic", 11, 11),
          ("C11/del-gen(删a¹¹)", C11, [0], "Cyclic", 11, 11),
          ("C11/del-red", C11, [1], "Cyclic", 11, 11)]
    # C13 = 循环群
    C13=[["R_gen",13,13],["R_gen_red",1,13]]
    S += [("C13/orig", C13, [], "Cyclic", 13, 13),
          ("C13/del-gen", C13, [0], "Cyclic", 13, 13),
          ("C13/del-red", C13, [1], "Cyclic", 13, 13)]
    # D7full：非循环但关系全在（对照 v5 时代 「D7full→full→0」）
    S += [("D7-extra-gen(加冗余,orig)", [["R_gen",7,7],["R_gen",2,2],["R_comm",0,0],["R_gen_red",1,7]], [], "Dihedral", 14, 14),
          ("D7-extra-gen/del-red", [["R_gen",7,7],["R_gen",2,2],["R_comm",0,0],["R_gen_red",1,7]], [3], "Dihedral", 14, 14)]
    # Alt5（非循环、非二面体的 unseen 族替代：这里用 I 的 del 变体做交叉验证——I 在训练里出现过，
    # 但用「未见的阶」组合：60 阶的 del-comm 在 v9 训练里见过 sg_I 变体……换一个真正的未见族 )
    return S

def main():
    recs=json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),"group_dataset_rel_v9.json")))
    rel_types=sorted({rt for r in recs for rt,_,_ in r["relations"]})
    # 训练 v9 模型（与 train_causal_v9.py 相同）
    rows=[(featurize(r,rel_types),(r["y_order"]+r["y_abelian"])/2.0) for r in recs]
    X=[x for x,_ in rows]; y=[t for _,t in rows]
    w,b=train(X,y)
    print("=== v12 在线符号裁决器 · 神经提议 × 符号验证（unseen 真实群）===")
    print(f"关系类型模板（来自训练集）: {rel_types}")
    unseen=make_unseen()
    npass=nwarn=0
    for nm, rels, masked, fam, order, ngen in unseen:
        # 神经提议：对未见样本特征化（需要关系类型索引；未见过类型不可用——这里全部用已知类型）
        r=R(rels, masked, fam, order, ngen)
        x=featurize(r, rel_types)
        p=pred(w,b,x)
        neural=bucket(p)
        # 符号裁决
        do, basis=symbol_verdict(rels, masked, fam, order)
        # 神经标签 = 提议 Δorder（神经只出复合 0/0.5；裁决只比 Δorder 维度）
        neural_do = 1 if neural==2 or (neural==1 and do==1) else (0 if neural==0 else None)
        # 简化：神经输出 bucket ∈{0,1} 对应 y∈{0,0.5};两个都是「order 与 abelian 的复合」。
        # 裁决只保证 Δorder。用「裁决 Δorder=1 → 复合应为 0.5(1)；否则 0」对账
        symbol_comp = 0.5 if do==1 else 0.0
        ok = (neural== (1 if symbol_comp==0.5 else 0)) or (neural==(0 if symbol_comp==0.0 else 2))
        # bucket 语义：0→orig类, 1→partial(0.5)
        agree = (neural==1 and symbol_comp==0.5) or (neural==0 and symbol_comp==0.0)
        if agree: npass+=1; tag="PASS"
        else: nwarn+=1; tag="WARN"
        print(f"  [{tag}] {nm:26s} 神经={neural}（p={p:.2f}） 符号Δorder={do}（{basis}）")
    print(f"\n裁决汇总: PASS={npass}  WARN={nwarn}（WARN=标注不拒绝，神经提议与符号真值分歧）")
    return 0 if nwarn==0 else 1

if __name__=="__main__":
    sys.exit(main())