#!/usr/bin/env python3
"""v16 checkpoint 版：**断点续训协议**（用户 2026-09-17 要求——模型不得活在内存态）。

断电/中断不丢：
  1. 训练前读 checkpoint（若存在）→ 从上次 epoch 续训（不从头）
  2. 每 save_every epoch 原子写盘：W/B/epoch/seed/数据哈希/时间戳
  3. 训练结束写最终 checkpoint（= 固化模型，含全部元数据）

用法：
  python3 train_causal_v16_checkpoint.py [--checkpoint model_causal_v19.json] [--epochs 8000]
断点恢复：再次运行同命令 → 从 checkpoint 的 epoch 续训（输出开始行显示续训来源）。
"""
import json, math, random, sys, os, time, hashlib, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from featurize_x import featurize_x
from train_causal_v15 import train3, predict3

def data_hash(recs):
    return hashlib.sha256(json.dumps(recs, sort_keys=True).encode()).hexdigest()[:16]

def load_checkpoint(path):
    if not os.path.exists(path): return None
    with open(path) as f: art=json.load(f)
    # 校验数据哈希（数据变了 → 旧权重无效，拒绝续训）
    return art

def save_checkpoint(path, W, B, rel_types, epoch, seed, data_h, acc):
    art={ "model":"causal-v16-3class", "version":16,
          "epoch":epoch, "seed":seed, "data_hash":data_h, "train_acc":acc,
          "created_at":time.strftime("%Y-%m-%d %H:%M:%S"),
          "trained_on":"group_dataset_rel_v16.json",
          "rel_types":rel_types, "featurize":"featurize_x (base+3 cross)",
          "W":W, "B":B,
          "label_map":{"0.0":"independent(orig/red)","0.5":"partial(order-changed)",
                       "1.0":"full(order+abelian-changed)"} }
    tmp=path+".tmp"
    with open(tmp,"w") as f: json.dump(art,f,indent=1)
    os.replace(tmp,path)   # 原子写：断电不会留下半截文件
    return art

def main():
    here=os.path.dirname(os.path.abspath(__file__))
    ap=argparse.ArgumentParser()
    ap.add_argument("--checkpoint", default=os.path.join(here,"model_causal_v19.json"))
    ap.add_argument("--epochs", type=int, default=8000)
    ap.add_argument("--save-every", type=int, default=1000)
    args=ap.parse_args()

    recs=json.load(open(os.path.join(here,"group_dataset_rel_v16.json")))
    rel_types=sorted({rt for r in recs for rt,_,_ in r["relations"]})
    data_h=data_hash(recs)
    def rows(sub): return [(featurize_x(r,rel_types),(r["y_order"]+r["y_abelian"])/2.0) for r in sub]
    X=[x for x,_ in rows(recs)]; y=[t for _,t in rows(recs)]

    # 断点恢复：读 checkpoint
    cp=load_checkpoint(args.checkpoint)
    start_epoch=0; W=None; B=None; seed=7
    if cp:
        if cp.get("data_hash")!=data_h:
            print(f"⚠ 数据哈希不匹配（checkpoint {cp.get('data_hash')} vs 当前 {data_h}）——拒绝续训，从头训练")
        elif cp.get("epoch",0)>=args.epochs:
            print(f"checkpoint 已完成（epoch {cp['epoch']}≥{args.epochs}），无需训练"); return 0
        else:
            W=cp["W"]; B=cp["B"]; seed=cp.get("seed",7); start_epoch=cp["epoch"]
            print(f"✓ 从 checkpoint 恢复: epoch {start_epoch}/{args.epochs}（数据哈希一致 {data_h}）")
    else:
        print(f"无 checkpoint，从头训练（seed={seed}）")

    # 真断点续训：W/B 来自 checkpoint → 热启动继续 train3（从 start_epoch 续训）
    from train_causal_v15 import train3 as train3_hot
    Wc = None if W is None else W
    Bc = None if B is None else B
    # 续训目标 epochs：从 start_epoch 训练到 args.epochs
    total_target = args.epochs
    if Wc is not None:
        print(f"热启动续训: epoch {start_epoch} → {total_target}（已训部分不丢失）")
    else:
        print(f"从头训练: epoch 0 → {total_target}")
    # 中途存档：每 save_every epoch 存一次（断电保护），存的是当前 W/B+epoch
    last_saved=[start_epoch]
    def mid_save(ep):
        if ep > last_saved[0]:
            save_checkpoint(args.checkpoint,W,B,rel_types,ep,seed,data_h,
                            sum(1 for x,v in zip(X,y) if predict3(W,B,x)[0]==v)/len(X))
            last_saved[0]=ep
            print(f"  [盘中] epoch {ep} 已存档")
    W,B = train3_hot(X, y, epochs=total_target, seed=seed,
                     W0=Wc, B0=Bc, start_epoch=start_epoch,
                     on_epoch=mid_save, save_every=args.save_every)
    acc=sum(1 for x,v in zip(X,y) if predict3(W,B,x)[0]==v)/len(X)
    save_checkpoint(args.checkpoint,W,B,rel_types,total_target,seed,data_h,acc)
    print(f"✓ checkpoint 已写盘: {args.checkpoint}")
    print(f"  训练 acc={acc:.3f}  data_hash={data_h}  epoch={total_target}")
    return 0

if __name__=="__main__": sys.exit(main())
