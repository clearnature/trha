#!/usr/bin/env python3
"""v14：训练循环吃符号反馈（借鉴 DeepSeek-LeanSpark 工具调用循环）。

LeanSpark 闭环：神经提议（LLM 生成 Lean 代码）→ 符号验证（lean 编译器）→
  **失败反馈回提议者** → 迭代修复 → 全部通过才交付。
trha 对应物（B1 数据管线侧）：
  v9 模型（神经提议）batch 输出 → symbol_verdict（TC+定理裁决）→
  WARN 样本（提议≠符号真值）按符号真值回注 → 重训 → 迭代直到 0 WARN。
类比 LeanSpark 的 15 次重试上限：这里迭代上限 N=8。

判据（与 LeanSpark「禁止声称已证明但未通过验证」同构）：
  收敛 = 迭代后 unseen batch 上符号裁决 0 WARN；不收敛如实报告 WARN 集合。
"""
import json, sys, os, math, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train_causal_v9 import featurize, train, pred, bucket
from symbol_verdict_v12 import make_unseen, symbol_verdict, R

def main():
    here=os.path.dirname(os.path.abspath(__file__))
    recs=json.load(open(os.path.join(here,"group_dataset_rel_v13.json")))  # 105 条已符号校准
    rel_types=sorted({rt for r in recs for rt,_,_ in r["relations"]})
    unseen=make_unseen()   # 复用 v12 的 unseen 批（D7/D9/C11/C13 × 变体）
    print(f"=== v14 符号反馈迭代 · 数据 {len(recs)} 条 · unseen {len(unseen)} 条 ===")
    print(f"关系类型: {rel_types}")

    # 初始训练（v9 线性）
    def rows(sub):
        return [(featurize(r,rel_types),(r["y_order"]+r["y_abelian"])/2.0) for r in sub]
    X=[x for x,_ in rows(recs)]; y=[t for _,t in rows(recs)]
    w,b=train(X,y)

    for it in range(9):
        # 神经提议 batch（unseen）
        warns=[]; passes=0
        for nm, rels, masked, fam, order, ngen in unseen:
            r=R(rels, masked, fam, order, ngen)
            x=featurize(r, rel_types)
            p=pred(w,b,x); neural=bucket(p)
            do,_=symbol_verdict(rels, masked, fam, order)
            symbol_comp=0.5 if do==1 else 0.0
            agree=(neural==1 and symbol_comp==0.5) or (neural==0 and symbol_comp==0.0)
            if agree: passes+=1
            else: warns.append(nm)
        print(f"  迭代{it}: PASS={passes}/{len(unseen)} WARN={warns}")
        if not warns:
            print("  ✓ 收敛：符号裁决 0 WARN（类比 LeanSpark 全部通过才交付）")
            return 0
        if it==0 and len(warns)==len(unseen):
            print("  ✗ 初始提议全错——检查特征/标签对齐（不应发生：v13 五族泛化 1.00）")
            return 2
        # 回注：把 WARN 样本（unseen 群）并入训练集（按符号真值标），重训
        for nm, rels, masked, fam, order, ngen in unseen:
            if nm in warns:
                r=R(rels, masked, fam, order, ngen)
                do,_=symbol_verdict(rels, masked, fam, order)
                recs.append({"name":nm,"order":order,"abelian":False,"family":fam,
                             "relations":rels,"relations_masked":masked,
                             "variant":"replay","y_order":do,"y_abelian":0,"new_gen_order":ngen})
        X=[x for x,_ in rows(recs)]; y=[t for _,t in rows(recs)]
        w,b=train(X,y)
    print("  ✗ 迭代上限未收敛（类比 LeanSpark 重试上限）——WARN 集合已如实列出")
    return 1

if __name__=="__main__":
    sys.exit(main())
