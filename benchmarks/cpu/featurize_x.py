"""featurize 交叉扩展：L1 编码补「删除×关系类型×保留结构」交互信号。

v16 诊断（j-mu6fg61x-i096）：线性 bag 无法表达「R_commX 存在 × del-comm1 删除 × R_gen 未删」
= 双变化(1.0)的信号。本版本在 v9 featurize 基础上追加交叉项：
  x_inter = [is_del_commX_and_gen_kept, is_del_comm_and_gen_kept, is_del_gen_only, ...]
其中 is_del_commX_and_gen_kept = 删除了一条 R_commX 且至少一条 R_gen 未被删。
"""
import math

def featurize_x(r, rel_types):
    from train_causal_v9 import featurize
    base=featurize(r, rel_types)
    masked=set(r["relations_masked"])
    has_gen_kept=False
    del_commX=False; del_comm=False; del_gen=False
    for i,rel in enumerate(r["relations"]):
        rt=rel[0]
        if i in masked:
            if rt=="R_commX": del_commX=True
            elif rt=="R_comm": del_comm=True
            elif rt.startswith("R_gen"): del_gen=True
        else:
            if rt.startswith("R_gen"): has_gen_kept=True
    # 交叉：删了交换 comm 且生成元关系保留 = 双变化信号（TC 判据：自由积非阿贝尔且阶变）
    x_cross=[0.0]*3
    if del_commX and has_gen_kept and not del_gen: x_cross[0]=1.0
    if del_comm and has_gen_kept and not del_gen: x_cross[1]=1.0
    if del_gen: x_cross[2]=1.0
    return base+x_cross
