#!/usr/bin/env python3
"""trha-causal-verdict：自建因果模型的独立推理接口（草稿模型最小闭环）。

不加载训练数据、不依赖训练脚本——只读固化权重 model_causal_v19.json。
输入：群的关系描述（relations 列表）+ 删除掩码；输出：三值因果裁决 (0/0.5/1.0)。

用法：
  python3 trha_causal_verdict.py --relations '[[\"R_gen\",5,5],[\"R_gen\",2,2],[\"R_comm\",0,0]]'
         --masked '[2]' --order 10
  （描述 Z5⋊Z2=D10 删反交换 → 应判 0.5）
"""
import json, math, os, sys, argparse

def featurize_x(r, rel_types):
    """与 featurize_x.py 完全一致（推理侧复制，保证可独立运行）。"""
    bag=[0.0]*(len(rel_types)*4)
    masked=set(r["relations_masked"])
    for i,rel in enumerate(r["relations"]):
        rt=rel[0]
        if i in masked: continue
        t=rel_types.index(rt); b=min(3,int(math.log(rel[1]+1)/1.5))
        bag[t*4+b]+=1.0
    is_del=1.0 if r["relations_masked"] else 0.0
    base=bag+[math.log(r["order"]+1)/5.0, math.log(r["new_gen_order"]+1)/5.0, is_del]
    has_gen_kept=False; del_commX=False; del_comm=False; del_gen=False
    for i,rel in enumerate(r["relations"]):
        rt=rel[0]
        if i in masked:
            if rt=="R_commX": del_commX=True
            elif rt=="R_comm": del_comm=True
            elif rt.startswith("R_gen"): del_gen=True
        else:
            if rt.startswith("R_gen"): has_gen_kept=True
    x_cross=[0.0]*3
    if del_commX and has_gen_kept and not del_gen: x_cross[0]=1.0
    if del_comm and has_gen_kept and not del_gen: x_cross[1]=1.0
    if del_gen: x_cross[2]=1.0
    return base+x_cross

def softmax3(W,B,x):
    import math as m
    zs=[sum(W[k][i]*x[i] for i in range(len(x)))+B[k] for k in range(3)]
    mx=max(zs); es=[m.exp(z-mx) for z in zs]; s=sum(es)
    return [e/s for e in es]

def predict(W,B,rel_types,relations,masked,order,new_gen_order):
    assert all(rt in rel_types for rt,_,_ in relations), f"未知关系类型: {set(rt for rt,_,_ in relations) - set(rel_types)}"
    r={"relations":relations,"relations_masked":masked,"order":order,"new_gen_order":new_gen_order}
    x=featurize_x(r, rel_types)
    ps=softmax3(W,B,x)
    cls=max(range(3), key=lambda k: ps[k])
    return [0.0,0.5,1.0][cls], ps, x

def main():
    ap=argparse.ArgumentParser(description="trha 自建因果模型独立推理")
    ap.add_argument("--relations", required=True, help='JSON: [["R_gen",5,5],["R_gen",2,2],["R_comm",0,0]]')
    ap.add_argument("--masked", default="[]", help='JSON: 被删关系索引 [2]')
    ap.add_argument("--order", type=int, required=True, help="群阶")
    ap.add_argument("--new-gen-order", type=int, default=None, help="删后生成元阶（缺省=order）")
    ap.add_argument("--model", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),"model_causal_v19.json"))
    args=ap.parse_args()
    with open(args.model) as f: art=json.load(f)
    relations=json.loads(args.relations); masked=json.loads(args.masked)
    ngo=args.new_gen_order if args.new_gen_order is not None else args.order
    lab, ps, x = predict(art["W"], art["B"], art["rel_types"], relations, masked, args.order, ngo)
    print(f"rel_types={art['rel_types']}")
    print(f"关系: {relations}  删除: {masked}  阶: {args.order}")
    print(f"神经提议: {lab}  分布: {[round(p,3) for p in ps]}")
    print(f"语义: {art['label_map'][str(lab)]}")
    return 0

if __name__=="__main__":
    sys.exit(main())