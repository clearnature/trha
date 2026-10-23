# 仓颉类型系统能力探针

> **用途**：回答「仓颉的类型系统能不能承载 trha 的约束内核」这个问题——**不查文档，直接问编译器**。
> **日期**：2026-09-21 ｜ **编译器**：Cangjie `1.3.0-alpha.20260919003053`（cjnative，nightly）
> **跑法**：`bash run.sh`（需先 `source envsetup.sh`）。断言写在 `run.sh` 的 `EXPECT` 里，能力变了会报。

## 结果总表

| 探针 | 能力 | 期望 | 编译器判定 |
|---|---|---|---|
| `p4_fbound` | 约束泛型 + F-bounded 多态 | pass | ✅ **支持** |
| `p7ok` / `p7ok_phantom` | **幻影类型范畴隔离**（正确用法） | pass | ✅ **支持** |
| `p7_phantom` | 同上（跨范畴混用） | fail | ✅ **编译器正确拒绝** |
| `p5_gadt` | 泛型枚举声明 | pass | ✅ 可声明（**弱测试**，见下） |
| `p6_gadt2` | **真 GADT**：构造子 refine 类型参数 | fail | ❌ **不支持** |
| `p1_hkt` | **高阶类型（HKT）**：对类型构造子抽象 | fail | ❌ **不支持** |
| `p2_assoc` | **关联类型**（interface 内声明 `type`） | fail | ❌ **不支持** |
| `p3_typelvl` | **类型级 / 依赖类型参数** | fail | ❌ **不支持**（语法不存在） |

**其余能力（扫描得出，非本目录探针）**：`std.sync` 有 `Mutex` / `Condition` / `Semaphore` / `Atomic*` / `SyncCounter`，**无 STM / TVar**。

## 编译器原文（留证）

```
p1_hkt      error: type argument's number does not match type parameter's number
            ==> func fmap<A, B>(f: (A) -> B, x: F<A>): F<B>
                                                       ^^^^
p2_assoc    error: unexpected type alias declaration in interface body
            ==>     type Elem
                    ^^^^ unexpected type alias declaration
p3_typelvl  error: unclosed delimiter: '<'
            ==> func vec<n: Int64>(): Int64
                        ~ ^ expected '>' here
p6_gadt2    error: mismatched types
            ==>         case LitInt(n) => return n
                                             ^ expected 'Generics-T', found 'Int64'
p7_phantom  error: unable to infer generic argument of this function
            note: following constraints for type variable 'Generics-Cat' cannot be solved:
                  'Struct-GF9 <: Generics-Cat'
                  'Generics-Cat <: Struct-Trit'
p7ok        （无输出，编译通过；运行打印 3）
```

## 对 trha 的意义（结论摘要）

trha 的 ★核心手法（`SovereignTypes.hs`：*「为每个范畴定义独立类型，构造子不导出，只走 smart constructor，混淆在编译期被拒绝」*）
= `newtype` + 幻影参数 + 智能构造子 —— **实测在仓颉里完全可行**（`p7_phantom` 被拒 / `p7ok` 通过）。

仓颉类型系统的档位 ≈ **Rust**（ADT + 模式匹配 + 约束泛型 + 幻影类型），
**低于 GHC 一档**（无 HKT / 关联类型 / GADT / 类型级计算）。

详见同目录的 [`cangjie-replacement-feasibility.md`](../cangjie-replacement-feasibility.md)。

## 两个踩过的坑（避免误判）

1. **`Unit` 是仓颉保留关键字**（单元类型），不能当泛型参数名。
   `struct Quantity<Unit>` 报的是**语法错**（`expected a generic type name after '<'`），
   不是类型系统限制 —— 我第一版 `p7`（`p7ok_phantom.cj` 也保留了同一处写法）就是这样误撞的，换 `Cat` 后正常。
2. **`cjc` 不允许 `-o /dev/null`**，报 `error: Permission denied: '/dev'`。用真实路径或 `mktemp -d`。

## 文件清单

| 文件 | 说明 |
|---|---|
| `p1_hkt.cj` | 高阶类型：`interface Functor<F> { func fmap<A,B>(f:(A)->B, x:F<A>): F<B> }` |
| `p2_assoc.cj` | 关联类型：`interface Container { type Elem; ... }` |
| `p3_typelvl.cj` | 类型级参数：`func vec<n: Int64>()` |
| `p4_fbound.cj` | 对照：`func same<A>(x: A, y: A): Bool where A <: Eq<A>` |
| `p5_gadt.cj` | 泛型枚举声明（弱：只证明能声明，未验证 refine） |
| `p6_gadt2.cj` | 真 GADT：`case LitInt(n) => return n` 需要 `T ≡ Int64` |
| `p7_phantom.cj` | 幻影隔离：`Quantity<Trit>` 与 `Quantity<GF9>` 相加 → 应被拒 |
| `p7ok.cj` | 幻影隔离正确用法 → 应通过并打印 3 |
| `pitfall_unit_keyword.cj` | **坑样本（非能力探针）**：用 `Unit` 当泛型参数名 → 应报语法错。留档以免后人误判成类型系统限制 |
