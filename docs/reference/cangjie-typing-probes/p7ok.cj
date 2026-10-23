struct Trit {}
struct Quantity<Cat> {
    let v: Int64
    public init(v: Int64) { this.v = v }
}
func add<Cat>(a: Quantity<Cat>, b: Quantity<Cat>): Quantity<Cat> {
    return Quantity<Cat>(a.v + b.v)
}
main(): Int64 {
    let c = add(Quantity<Trit>(1), Quantity<Trit>(2))
    println("${c.v}")          // 期望通过并打印 3
    return 0
}
