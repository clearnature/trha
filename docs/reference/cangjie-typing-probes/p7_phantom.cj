// 幻影类型隔离：不同范畴的类型不可混用（trha「类型化范畴隔离」的实际形态）
struct Trit {}
struct GF9 {}
struct Quantity<Cat> {
    let v: Int64
    public init(v: Int64) { this.v = v }
}
func add<Cat>(a: Quantity<Cat>, b: Quantity<Cat>): Quantity<Cat> {
    return Quantity<Cat>(a.v + b.v)
}
main(): Int64 {
    let a = Quantity<Trit>(1)
    let b = Quantity<GF9>(2)
    let _ = add(a, b)          // 期望编译失败：Trit ≠ GF9
    return 0
}
