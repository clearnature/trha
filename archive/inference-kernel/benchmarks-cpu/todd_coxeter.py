#!/usr/bin/env python3
"""Todd-Coxeter 单表（coset table enumeration，对单位元陪集）。

gens = [(name, order)]；rels = [词]；词 = 生成元索引序列（正=ga，负=逆）。
返回单位表陪集数（= 群阶）；超过 max_cosets 返回 None（疑似无限）。
标准骨架：定义表 + 关系词逐字母扫描，未定义边新建陪集，闭合失败则合并陪集。
"""
from collections import deque

def enume_group(gens, rels, max_cosets=300000):
    n = len(gens)
    def idx_of(a):      # 列：1..n → 0..n-1；-1..-n → n..2n-1
        return (a-1) if a > 0 else (n + (-a) - 1)
    def inv_of(a): return -a

    # 全部关系词（含 g^order=e）
    all_rels = []
    for gi, (nm, order) in enumerate(gens):
        all_rels.append(tuple([gi+1]*order))
    for w in rels:
        ew = []
        for s in w:
            g = abs(s)-1
            if -n <= s <= n and s != 0:
                ew.append(s)          # 正负字母原样保留（逆是 TC 表的独立列）
            else:
                raise ValueError(f"越界字母 {s}（生成元数 {n}）")
        all_rels.append(tuple(ew))

    # 并查集
    parent = {}
    def new_coset():
        c = len(parent) + 1
        parent[c] = c
        return c
    def find(c):
        p = parent.get(c, c)
        while parent.get(p, p) != p:
            parent[p] = parent.get(parent.get(p, p), parent.get(p, p))
            p = parent[p]
        return p
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra
            return ra
        return ra

    # 定义表 T[(coset, col)] = target（raw，未 find）
    T = {}
    def get(c, a):
        t = T.get((find(c), idx_of(a)), 0)
        return 0 if t == 0 else find(t)
    def put(c, a, t):
        T[(find(c), idx_of(a))] = t

    # 合并 u 到 v（u 成为 v 的别名）
    def merge(u, v):
        ru, rv = find(u), find(v)
        if ru == rv: return
        # 先处理 ru 的各出边
        for a in range(1, n+1):
            for s in (a, -a):
                ci = idx_of(s)
                t = T.pop((ru, ci), None)
                if t is None or t == 0: continue
                t = find(t)
                o = T.get((rv, ci), 0)
                if o == 0:
                    T[(rv, ci)] = t
                elif find(o) != t:
                    merge(t, o)          # 两个 target 冲突 → 合并 target
        parent[ru] = rv

    start = new_coset()  # coset 1
    dq = deque((start, r) for r in all_rels)
    while dq:
        c, w = dq.popleft()
        x = find(c)
        for a in w:
            t = get(x, a)
            if t == 0:
                t = new_coset()
                if t > max_cosets: return None
                put(x, a, t)
                put(t, inv_of(a), x)
                for rr in all_rels:
                    dq.append((t, rr)); dq.append((x, rr))
            x = t
        # 闭合要求：词末应回到起点
        if find(x) != find(c):
            merge(x, c)

    # 有效陪集数
    seen = set()
    for (c, _), t in T.items():
        if t != 0:
            seen.add(find(c)); seen.add(find(t))
    return len(seen)

if __name__ == "__main__":
    tests = [
        ("⟨a³,b²,(ab)³⟩ → A4=12", [("a",3),("b",2)], [(1,2,1,2,1,2)], 12),
        ("⟨a³,b²⟩ 自由积→∞", [("a",3),("b",2)], [], None),
        ("⟨a³,b²,[a,b]⟩ → C6", [("a",3),("b",2)], [(1,2,-1,-2)], 6),
        ("⟨r³,s²,srs=r⁻¹⟩ → D6", [("r",3),("s",2)], [(2,1,2,-1)], 6),
        # 注：无交换/反交换约束的双生成元 = 自由积（无限）。⟨r³,s²⟩ 是 C3*C2 自由积，
        # 不是 C6（C6 需要 [r,s]=1）；⟨r⁴,s²⟩ 同理 C4*C2。⟨a²,b²,c²,(ab)³,...⟩
        # 无任何 comm 约束 = 三因子自由积（无限），不是 24 阶 O 群（O 需 (ab)² 类反交换）。
        ("⟨r³,s²⟩ 自由积→∞", [("r",3),("s",2)], [], None),
        ("⟨r⁴,s²,srs=r⁻¹⟩ → D8", [("r",4),("s",2)], [(2,1,2,-1)], 8),
        ("⟨r⁴,s²⟩ 自由积→∞", [("r",4),("s",2)], [], None),
        ("⟨a²,b²,c²,(ab)³,(bc)³,(ca)³=1⟩ 多因子自由积→∞", [("a",2),("b",2),("c",2)],
         [(1,2,1,2,1,2),(2,3,2,3,2,3),(3,1,3,1,3,1)], None),
        # 八面体群 O(24)：⟨a,b | a⁴, b³, (ab)²⟩（正八面体旋转群标准演示）
        ("⟨a⁴,b³,(ab)²⟩ → O=24", [("a",4),("b",3)],
         [(1,2,1,2)], 24),
    ]
    for name, gens, rels, expect in tests:
        k = enume_group(gens, rels)
        ok = (k == expect) or (expect is None and k is None)
        print(f"{'PASS' if ok else 'FAIL '} {name}: 得 {k}（期望 {expect}）")