#!/usr/bin/env bash
# 重跑「仓颉类型系统能力」探针，并断言预期结果。
#
# 前置：已 source 仓颉 envsetup.sh（使 cjc 可用）。
# 用法：bash run.sh        # 全部
#       bash run.sh p7     # 只跑名字含 p7 的
#
# 每个探针是**独立的单文件编译**，断言「应当通过 / 应当失败」。
# 期望值写死在 EXPECT 里 —— 仓颉升级后若某项能力变了，这里会响。
set -uo pipefail
cd "$(dirname "$0")" || exit 1

# 探针名 -> 期望结果（pass = 应编译通过；fail = 应编译失败）
declare -A EXPECT=(
  [p1_hkt]=fail        # 高阶类型（HKT）：对类型构造子抽象
  [p2_assoc]=fail      # 关联类型：interface 体内声明 type
  [p3_typelvl]=fail    # 类型级/依赖类型参数
  [p4_fbound]=pass     # 对照：约束泛型 + F-bounded 多态
  [p5_gadt]=pass       # 泛型枚举（弱测试，仅证明可声明）
  [p6_gadt2]=fail      # 真 GADT：构造子能否 refine 类型参数
  [p7_phantom]=fail    # 幻影类型隔离：跨范畴混用应被拒绝
  [p7ok]=pass          # 幻影类型隔离：同范畴正确用法
  [pitfall_unit_keyword]=fail  # 坑样本：Unit 是保留字 → 应报语法错（非能力探针）
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

filter="${1:-}"
fail=0
total=0
for name in $(printf '%s\n' "${!EXPECT[@]}" | sort); do
  if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then continue; fi
  total=$((total + 1))
  want="${EXPECT[$name]}"
  # 注意：cjc 不允许 -o /dev/null（报 Permission denied: '/dev'）
  if out=$(cjc "$name.cj" -o "$TMP/$name" 2>&1); then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    printf '  %-14s %-5s  ✅ 符合预期\n' "$name" "$got"
  else
    printf '  %-14s %-5s  ❌ 预期 %s —— 能力变了，需更新本文档\n' "$name" "$got" "$want"
    printf '%s\n' "$out" | head -6 | sed 's/^/        /'
    fail=$((fail + 1))
  fi
done

echo
echo "  $((total - fail))/$total 符合预期"
[ "$fail" -eq 0 ] || exit 1
