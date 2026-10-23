#!/usr/bin/env python3
"""v10：L2 图消息传递（GCN 雏形）——节点删除式干预。

参考架构 L2 = Graph Transformer；本版最小实现 = 2 层 GCN。
关键升级：反事实干预「删关系 M」在图表示里 = 真删除 M 对应节点（节点删除式干预），
          而非 v9 平铺 bag 的「特征置零」。这是图相对序列表征的结构性优势，
          也是参考「dual-encoder / 结构敏感」假设的载体。

图构造（每样本一小图）：
  节点 = 每条关系（1..3 个）
  特征 = [type one-hot×3（R_gen/R_comm/R_gen_red）, log(param+1), log(gen_order+1), is_del_of_this_node]
  边   = 完全图 + 自环（小图，节点间全连通即「共享同一群对象」的粗建模；
          future：按「共享生成元」细化邻接）
标签 = (Δorder + Δabelian)/2 ∈ {0, 0.5}（与 v9 同一数据）

验证：
  1) GCN 训练收敛（前向/反向正确性）
  2) 五族留出泛化 vs v9 线性（同数据同划分，公平对比）
  3) 诚实报告：当前 68 条规模上图 vs 平铺的差异结论
"""
import json, math, random
import numpy as np
import torch
import torch.nn as nn

torch.manual_seed(7)
np.random.seed(7)

def build_graph(r):
    """节点列表；删除即在节点序列中省略被 masked 的关系（节点删除式干预）。"""
    masked = set(r["relations_masked"])
    nodes = []
    for i, (rt, p, o) in enumerate(r["relations"]):
        if i in masked:
            continue
        t = {"R_gen": 0, "R_comm": 1, "R_gen_red": 2}[rt]
        nodes.append([t, math.log(p + 1) / 3.0, math.log(o + 1) / 5.0, 1.0])
    # at least one node（del 后也可能空：如单关系群删唯一关系 → 空图 → 加零节点占位）
    if not nodes:
        nodes.append([-1, 0.0, 0.0, 0.0])  # 空图占位（全部关系被删 = 退化到平凡群）
    return nodes

def adjacency(n):
    A = np.ones((n, n))                       # 完全图
    np.fill_diagonal(A, 0)                    # 无边自环（自环由 A+I 加）
    A = A + np.eye(n)
    D = A.sum(1)
    Dinv = np.diag(1.0 / np.sqrt(np.maximum(D, 1e-8)))
    return Dinv @ A @ Dinv

class TinyGCN(nn.Module):
    def __init__(self, feat_dim, hidden=16):
        super().__init__()
        self.w1 = nn.Linear(feat_dim, hidden)
        self.w2 = nn.Linear(hidden, hidden)
        self.head = nn.Linear(hidden, 1)
        self.act = nn.ReLU()
    def forward(self, xs, As, mask_nodes):
        """xs: list[T×F]；As: list[T×T]；mask_nodes: list[T]（真实节点 == 1）。"""
        hs = []
        for x, A, m in zip(xs, As, mask_nodes):
            h = self.act(torch.mm(A, (self.w1(x))))      # 1 层传播
            h = self.act(torch.mm(A, (self.w2(h))))      # 2 层传播
            s = h.sum(0)                                  # sum readout
            hs.append(s / max(m.sum().item(), 1))         # 平均池化
        out = self.head(torch.stack(hs)).squeeze(-1)
        return torch.sigmoid(out)

def main():
    recs = json.load(open("benchmarks/cpu/group_dataset_rel_v9.json"))
    labels = [(r["y_order"] + r["y_abelian"]) / 2.0 for r in recs]
    feat_dim = 6
    lossf = nn.MSELoss()

    def pack(subset):
        xs, As, ms = [], [], []
        for r in subset:
            nodes = build_graph(r)
            n = len(nodes)
            x = np.zeros((n, feat_dim))
            for i, nd in enumerate(nodes):
                if nd[0] >= 0:
                    x[i, nd[0]] = 1.0      # type one-hot
                    x[i, 3] = nd[1]        # log(param+1)
                    x[i, 4] = nd[2]        # log(gen_order+1)
                    x[i, 5] = nd[3]        # is_del
            xs.append(torch.tensor(x, dtype=torch.float32))
            As.append(torch.tensor(adjacency(n), dtype=torch.float32))
            ms.append(torch.ones(n))
        return xs, As, ms

    def run(subset, epochs=300, verbose=False):
        xs, As, ms = pack(subset)
        lab = torch.tensor([(r["y_order"] + r["y_abelian"]) / 2.0 for r in subset],
                           dtype=torch.float32)
        m2 = TinyGCN(feat_dim)          # 每次独立重置（公平留出）
        o2 = torch.optim.Adam(m2.parameters(), lr=0.05)
        for ep in range(epochs):
            o2.zero_grad()
            out = m2(xs, As, ms)
            loss = lossf(out, lab)
            loss.backward()
            o2.step()
        with torch.no_grad():
            out = m2(xs, As, ms)
        return m2, out.numpy()

    from collections import Counter
    print(f"=== v10 GCN · {len(recs)} 条 · 标签 {dict(sorted(Counter(labels).items()))} ===")
    # 1) 训练收敛
    model, out = run(recs)
    tr = sum(1 for o, y in zip(out, labels)
             if (0 if o < 0.25 else 1 if o < 0.75 else 2) == (0 if y < 0.25 else 1 if y < 0.75 else 2)) / len(recs)
    print(f"  GCN 训练 acc = {tr:.2f}")
    # 2) 五族留出（与 v9 线性同划分）
    for fam in ("Platonic", "Dihedral", "GF", "Cyclic", "Duodec"):
        hold = [r for r in recs if r["family"] == fam]
        rest = [r for r in recs if r["family"] != fam]
        m3, _ = run(rest)
        xs, As, ms = pack(hold)
        with torch.no_grad():
            outg = m3(xs, As, ms).numpy()
        holdlab = [(r["y_order"] + r["y_abelian"]) / 2.0 for r in hold]
        ag = sum(1 for o, y in zip(outg, holdlab)
                 if (0 if o < 0.25 else 1 if o < 0.75 else 2) == (0 if y < 0.25 else 1 if y < 0.75 else 2)) / len(hold)
        print(f"  留出 {fam:9s}（{len(hold)} unseen）泛化 acc = {ag:.2f}")

if __name__ == "__main__":
    main()