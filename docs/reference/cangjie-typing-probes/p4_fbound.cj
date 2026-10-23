// 探针 4（对照组）：约束泛型 + F-bounded 多态
interface Eq<T> { func eq(other: T): Bool }
func same<A>(x: A, y: A): Bool where A <: Eq<A> { return x.eq(y) }
main(): Int64 { return 0 }
