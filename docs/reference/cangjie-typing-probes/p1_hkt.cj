// 探针 1：高阶类型（HKT）——能否对"类型构造子"抽象？
interface Functor<F> {
    func fmap<A, B>(f: (A) -> B, x: F<A>): F<B>
}
main(): Int64 { return 0 }
