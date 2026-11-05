#!/usr/bin/env python3
"""检测被遮蔽的重复等式（死代码）。

Haskell 的多等式按顺序匹配：前面命中后，后面的等价等式永远不执行，而编译器
不会报错（`-Woverlapping-patterns` 在未开 `-Wall` 时也不启用，而且它只提示
「模式重叠」，不会指出「这条是死代码」）。

这类缺陷的症状很隐蔽：`Commands/Plan.hs` 里 `go AbandonPlan` 曾出现两次，
后一次把参数误写成 "reject"，因为被前一次遮蔽而永久不生效——功能上看不出
任何异常，直到有人调整等式顺序才会暴露。

检查两类：
  1. 普通等式   name pat = ...
  2. 守卫式     name pat 后跟 | guard = ...（比较「模式 + 全部守卫」）

判定时把模式里的变量归一化为 `_`，所以 `(Loop arg)` 与 `(Loop x)` 视为同一模式；
守卫条件不同的多等式是合法的（如 j/k 导航 vs 可打印字符），不会误报。

用法：
    python3 scripts/check-duplicate-equations.py            # 扫描 packages/app/CLI
    python3 scripts/check-duplicate-equations.py FILE...     # 扫描指定文件

退出码：发现问题返回 1（可直接用于 CI）。
"""
import collections
import glob
import re
import sys

# 这些不是函数定义，而是关键字/子句
KEYWORDS = {
    'deriving', 'else', 'then', 'let', 'case', 'of', 'if', 'where', 'do', 'in',
    'instance', 'type', 'data', 'newtype', 'class',
}

_VAR = re.compile(r"(?<!['\"\w])([a-z][A-Za-z0-9_']*)(?!['\"\w])")
_DEF = re.compile(
    r"^(    )?([a-z][a-zA-Z0-9_']*)\s+(\(.+\)|[A-Z][A-Za-z0-9_']*)\s*(=|$)"
)


def normalize(pattern: str) -> str:
    """把模式里的变量名统一成 `_`，保留构造子与字面量。"""
    return _VAR.sub('_', pattern)


def scan(path: str) -> list:
    lines = open(path, encoding='utf-8').read().split('\n')
    plain = collections.defaultdict(list)    # (name, norm_pat) -> [行号]
    guarded = collections.defaultdict(list)  # (name, norm_pat, norm_guards) -> [行号]

    i = 0
    while i < len(lines):
        m = _DEF.match(lines[i])
        if not m or m.group(2) in KEYWORDS:
            i += 1
            continue

        name, pat, ends_with_eq = m.group(2), m.group(3).strip(), m.group(4) == '='
        # 排除 do 块里的语句（return/liftIO/appendMsg… 不是函数等式）
        prev = lines[i - 1].strip() if i > 0 else ''
        if prev.endswith('do') or '<-' in prev or prev.startswith('let'):
            i += 1
            continue

        if ends_with_eq:
            plain[(name, normalize(pat))].append(i + 1)
            i += 1
            continue

        # 守卫式：收集紧随其后的 | guard = ... arm
        guards = []
        j = i + 1
        while j < len(lines) and re.match(r'^\s+\|', lines[j]):
            guards.append(re.sub(r'\s*=\s.*$', '', lines[j].strip()))
            j += 1
        if guards:
            guarded[(name, normalize(pat), ' | '.join(normalize(g) for g in guards))].append(i + 1)
        i = j if j > i else i + 1

    problems = []
    for (name, pat), ls in plain.items():
        if len(ls) > 1:
            problems.append(f'{path}: {name} {pat} 重复定义于行 {ls}')
    for (name, pat, guards), ls in guarded.items():
        if len(ls) > 1:
            problems.append(f'{path}: {name} {pat} 守卫[{guards}] 重复于行 {ls}')
    return problems


def main() -> int:
    files = sys.argv[1:] or sorted(
        glob.glob('packages/app/CLI/**/*.hs', recursive=True)
    )
    problems = []
    for f in files:
        problems += scan(f)

    for p in problems:
        print(p)
    print(f'\n扫描 {len(files)} 个文件，发现 {len(problems)} 处被遮蔽的重复等式')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
