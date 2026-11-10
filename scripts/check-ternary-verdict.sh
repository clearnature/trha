#!/bin/sh
# 三值判定禁制（2026-11-11 裁定②）——判定词汇表里不许出现二值布尔。
#
# 为什么：现有智能体的底层是 0/1 训练出来的，其输出天然非黑即白；内核若也用
# 二值布尔裁定，就只剩橡皮图章。判定的值域必须落在内核原生的三态系数
# （GF(3) / Trit，系数 0/1/2，见 Sov.Types 与 Sov.ConstraintVerdict）。
#
# 禁什么（在本脚本的 TARGETS 判定层模块里出现即显式报错、非零退出）：
#   * Bool        —— 二值类型不得进入判定词汇表（连注释都不行，与 no-float 门禁同纪律）
#   * VerdictWarn —— 旧二值判定的构造子（已被 VerdictHold/VerdictReject 取代）
#   * &&  ||      —— 布尔折叠算子：判定走三值归纳（verdictFromReach），不走布尔化简
#
# 接线：npm run verify:ternary；.githooks/pre-push 每次推送前运行。
set -e
cd "$(git rev-parse --show-toplevel)"

status=0
for f in src/core/Sov/ConstraintVerdict.hs; do
  for tok in 'Bool' 'VerdictWarn' '&&' '||'; do
    if grep -n -F -e "$tok" "$f"; then
      echo "ERROR: $f 出现二值布尔词「$tok」—— 违反裁定②（2026-11-11，三值判定）：" >&2
      echo "       判定层的值域必须落在 GF(3)/Trit 三态系数上，禁止布尔类型与布尔折叠。" >&2
      status=1
    fi
  done
done
if [ "$status" -eq 0 ]; then
  echo "ternary verdict gate: ok (判定层无二值布尔词)"
fi
exit $status
