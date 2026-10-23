// 探针 5：GADT / 索引类型（类型下标决定构造子）
enum Expr<T> {
    | LitInt(Int64)          // 应为 Expr<Int64>
    | LitBool(Bool)          // 应为 Expr<Bool>
}
main(): Int64 { return 0 }
