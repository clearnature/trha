// 坑样本（不是能力探针）：Unit 是仓颉**保留关键字**（单元类型），不能当泛型参数名。
// 报的是语法错 'expected a generic type name after '<' in generic, found keyword Unit'，
// 不是类型系统限制。保留此文件是为了让后人不重复误判。
struct Trit {}
struct Quantity<Unit> {          // <-- 这里应该用 Cat 之类的名字
    let v: Int64
    public init(v: Int64) { this.v = v }
}
func add<Unit>(a: Quantity<Unit>, b: Quantity<Unit>): Quantity<Unit> {
    return Quantity<Unit>(a.v + b.v)
}
main(): Int64 {
    let c = add(Quantity<Trit>(1), Quantity<Trit>(2))
    println("${c.v}")
    return 0
}
