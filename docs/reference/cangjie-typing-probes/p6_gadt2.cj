// 真 GADT 测试：构造子必须能 refine 类型参数 T
enum Expr<T> {
    | LitInt(Int64)
    | LitBool(Bool)
}
func eval<T>(e: Expr<T>): T {
    match (e) {
        case LitInt(n) => return n      // 需要 T ≡ Int64
        case LitBool(b) => return b     // 需要 T ≡ Bool
    }
}
main(): Int64 { return 0 }
