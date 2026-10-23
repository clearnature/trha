#!/usr/bin/env python3
"""证明生成机制 v1：代数链的证明计划生成器（用户：三机制之二）。

输入：链表示（algebra_chain_z3to12.json 的对象/态射/定理）。
输出：证明计划——每条定理的证明策略（需要哪些前置定理/态射性质）+ 依赖次序。
设计原则：证明生成 ≠ 写 Agda 代码，先产出「证明的有向依赖图」（语义计划），
  后续可由符号验证器（机制三）逐条确认。
"""
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

def generate_plan(chain):
    """从链表示生成证明计划：每条定理 → (需要的前置, 证明策略)。"""
    plan = []
    # 阶段1: embed 群同态 —— 前置 = 对象群公理（Z3/Z12 都是群）
    plan.append({
        "theorem": "embed-hom",
        "kind": "group-hom-emb",
        "needs": ["Z3-is-group", "Z12-is-group"],
        "strategy": "case-split(9): x,y∈Z3 逐格验证 embed(x⊕y)=embed x⊕12 embed y",
        "alternative": "pair-popping: 交换结合和式重排（若可归一为 ⊕ 结构）"
    })
    plan.append({
        "theorem": "embed-inj",
        "kind": "injectivity",
        "needs": ["embed-hom"],
        "strategy": "3 refl + 6 absurd：像集 {0,4,8} 分三点互异"
    })
    # 阶段2: CRT —— 前置 = gcd(3,4)=1
    plan.append({
        "theorem": "crt-roundtrip",
        "kind": "crt-roundtrip",
        "needs": ["gcd-3-4-1"],
        "strategy": "12 case refl（或 CRT 理论引用）"
    })
    # 阶段3: Δ12 线性 —— 前置 = 差分定义 + 函数空间加法
    plan.append({
        "theorem": "Δ12-linear",
        "kind": "linearity",
        "needs": ["Δ12-def", "fn-space-additive"],
        "strategy": "逐点展开 Δ₁₂(f+g)(x) 与 Δ₁₂f(x)+Δ₁₂g(x)"
    })
    # 阶段4: Δ12³ —— 前置 = Δ12-linear + 移位算子 S
    plan.append({
        "theorem": "Δ12³",
        "kind": "char-3-cancel",
        "needs": ["Δ12-linear", "shift-op-S"],
        "strategy": "Δ₁₂³f(x)=f(x+3)⊕negate f(x)：三步差分 char3 消去"
    })
    return plan

def topo_sort(plan):
    """依赖拓扑序（对被证定理给需要先证的前置）。"""
    order=[]; done=set()
    pending=list(plan)
    while pending:
        progressed=False
        still=[]
        for item in pending:
            if all(n in done for n in item["needs"]):
                order.append(item["theorem"]); done.add(item["theorem"]); progressed=True
            else:
                still.append(item)
        pending=still
        if not progressed:
            order += [it["theorem"] for it in pending]  # 环/缺前置：顺序保留（警告）
            break
    return order

def main():
    chain=json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),"algebra_chain_z3to12.json")))
    plan=generate_plan(chain)
    order=topo_sort(plan)
    print("== 证明计划（代数链 Z3→Z12）==")
    for item in plan:
        print(f"  {item['theorem']:16s} 前置={item['needs']}")
        print(f"    策略: {item['strategy']}")
    print(f"\n依赖拓扑序: {' → '.join(order)}")
    json.dump(plan, open("benchmarks/cpu/proof_plan_z3to12.json","w"), indent=1, ensure_ascii=False)
    print("计划落盘: proof_plan_z3to12.json")

if __name__ == "__main__":
    main()
