/*
 * cbits/gf27_avx2.c —— GF(27) 行点积的 AVX2 实现，含运行时检测与标量回退。
 *
 * == 目的：数学结构的独立实现，不是提速
 *
 * ⚠️ 这份 C 层的价值在于：它给 GF(27) 的代数结构提供了**第 4 个独立实现**
 * （Haskell 标量 / C 标量 / 本文件 AVX2 / GPU 侧 WGSL kernel）。四者在同一批输入上
 * **逐元素全等**，才说明这个数学结构在异构实现下是一致的 —— 这是验证，不是优化。
 *
 * **性能不是判据**：本机实测 AVX2 版反而比标量慢（AVX2 的 i32gather 是微码，而 GF(27)
 * 乘法表仅 27 项、常驻 L1，标量查表已接近极限）。但这个事实**丝毫不影响它的验证价值** ——
 * 项目的判据是数学与理论的正确性，不是硬件速度（见 docs/plans/verification-criteria.md）。
 *
 * == 算法选择：查表而不是逐位多项式乘
 *
 * GF(27)* ≅ Z/26（乘法群周期），项目已有 gf27LogTable / gf27ExpTable：
 *
 *     a ⊗ b = exp[(log a + log b) mod 26]        （a ≠ 0 且 b ≠ 0）
 *     a ⊗ b = 0                                   （a = 0 或 b = 0）
 *
 * 另一种算法是"分解 trit + 多项式乘 + 归约"，但它需要 a%3、a/3、a/9，而
 * **AVX2 没有整数除法** —— 用倒数近似会破坏"逐元素全等"这种严格验收。
 * 查表只要整数加 + 条件减法（mod 26），完全避开除法。
 *
 * == 唯一权威在 Haskell 侧
 *
 * logT / expT / 以及 0..26 的三进制分解，**全部由 Haskell 传入或按编码约定派生**：
 * 数学约定（log/exp 表）不在 C 里重复定义，避免两处漂移。
 *
 * == 运行时派发
 *
 * 这个函数挂在**真链**上（SovereignGF27 → … → LLM.Adapter.Interface），所以必须
 * 运行时检测 AVX2 并提供标量回退 —— 与 wgpu-native 那次不同（那里可以假设库存在，
 * 这里不能假设 CPU 支持 AVX2）。
 */

#include <stdint.h>
#include <stddef.h>

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__)
#  include <immintrin.h>
#  define TRHA_X86 1
#else
#  define TRHA_X86 0
#endif

/* ------------------------------------------------------------------ */
/* 运行时检测                                                          */
/* ------------------------------------------------------------------ */

/* 返回 1 表示本机可用 AVX2（GCC/Clang 的 __builtin_cpu_supports）。 */
int trha_gf27_has_avx2(void)
{
#if TRHA_X86 && (defined(__GNUC__) || defined(__clang__))
    return __builtin_cpu_supports("avx2") ? 1 : 0;
#else
    return 0;
#endif
}

/* ------------------------------------------------------------------ */
/* 标量参照（与 Haskell 侧同构；也是非 AVX2 机器上的回退路径）           */
/* ------------------------------------------------------------------ */

/* GF(27) 加法 = 逐分量 mod 3。 */
static int32_t gf27_add_scalar(int32_t a, int32_t b)
{
    int32_t r0 = (a % 3 + b % 3) % 3;
    int32_t r1 = ((a / 3) % 3 + (b / 3) % 3) % 3;
    int32_t r2 = (a / 9 + b / 9) % 3;
    return r0 + 3 * r1 + 9 * r2;
}

/* GF(27) 乘法（查表；零元特判）。 */
static int32_t gf27_mul_scalar(int32_t a, int32_t b,
                               const int32_t *logT, const int32_t *expT)
{
    int32_t s;
    if (a == 0 || b == 0) {
        return 0;
    }
    s = logT[a] + logT[b]; /* 0..50 */
    if (s >= 26) {
        s -= 26;
    }
    return expT[s];
}

/* 行点积：acc ⊕= w[j] ⊗ x[j] */
static int32_t rowdot_scalar(const int32_t *w, const int32_t *x, int64_t n,
                             const int32_t *logT, const int32_t *expT)
{
    int32_t acc = 0;
    int64_t j;
    for (j = 0; j < n; j++) {
        acc = gf27_add_scalar(acc, gf27_mul_scalar(w[j], x[j], logT, expT));
    }
    return acc;
}

/* ------------------------------------------------------------------ */
/* AVX2 路径                                                           */
/* ------------------------------------------------------------------ */

#if TRHA_X86

/* 0..26 的三进制分解表（编码约定：n = n0 + 3·n1 + 9·n2）。
 * 这是**表示**约定（元素值 0..26 如何拆成三个 GF(3) 分量），不是数学约定；
 * 数学约定（log/exp）由 Haskell 传入。 */
static const int32_t TRHA_T0[27] = { 0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0,1,2 };
static const int32_t TRHA_T1[27] = { 0,0,0,1,1,1,2,2,2,0,0,0,1,1,1,2,2,2,0,0,0,1,1,1,2,2,2 };
static const int32_t TRHA_T2[27] = { 0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,2,2,2 };

/* 8 路并行行点积：累加器用 (Z/3)^3 分离表示，避免每次 mod 3 的除法。
 *
 * ⚠️ 必须加 target("avx2")：_mm256_* 是 always_inline 且要求 -mavx2，若整个编译单元
 * 不开 -mavx2 就会报 "target specific option mismatch"。用 per-function 的 target
 * 属性，既让这个函数用上 AVX2，又不必让整个库（含非 AVX2 机器要走的标量路径）都开
 * -mavx2。 */
#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("avx2")))
#endif
static int32_t rowdot_avx2(const int32_t *w, const int32_t *x, int64_t n,
                           const int32_t *logT, const int32_t *expT)
{
    const __m256i zero = _mm256_setzero_si256();
    const __m256i three = _mm256_set1_epi32(3);
    __m256i a0 = zero, a1 = zero, a2 = zero; /* 累加器的三个分量，各 ∈ 0..2 */
    int64_t j = 0;

    for (; j + 8 <= n; j += 8) {
        __m256i wv = _mm256_loadu_si256((const __m256i *)(const void *)(w + j));
        __m256i xv = _mm256_loadu_si256((const __m256i *)(const void *)(x + j));

        /* 零元掩码：w==0 或 x==0 → 乘积为 0 */
        __m256i isZero = _mm256_or_si256(_mm256_cmpeq_epi32(wv, zero),
                                         _mm256_cmpeq_epi32(xv, zero));

        /* a ⊗ b = exp[(log a + log b) mod 26]（零元处的结果会被掩掉） */
        __m256i lw = _mm256_i32gather_epi32((const int *)logT, wv, 4);
        __m256i lx = _mm256_i32gather_epi32((const int *)logT, xv, 4);
        __m256i s = _mm256_add_epi32(lw, lx); /* 0..50 */
        /* mod 26：0..50 最多减一次 26 */
        __m256i ge26 = _mm256_cmpgt_epi32(s, _mm256_set1_epi32(25));
        s = _mm256_sub_epi32(s, _mm256_and_si256(ge26, _mm256_set1_epi32(26)));
        __m256i prod = _mm256_i32gather_epi32((const int *)expT, s, 4);
        prod = _mm256_andnot_si256(isZero, prod); /* 零元 → 0 */

        /* 把 prod 拆成三个 GF(3) 分量（查表，避开整数除法） */
        __m256i p0 = _mm256_i32gather_epi32((const int *)TRHA_T0, prod, 4);
        __m256i p1 = _mm256_i32gather_epi32((const int *)TRHA_T1, prod, 4);
        __m256i p2 = _mm256_i32gather_epi32((const int *)TRHA_T2, prod, 4);

        /* 分量相加（0..4），再条件减 3 回到 0..2 */
        a0 = _mm256_add_epi32(a0, p0);
        a1 = _mm256_add_epi32(a1, p1);
        a2 = _mm256_add_epi32(a2, p2);
        {
            __m256i m0 = _mm256_cmpgt_epi32(a0, _mm256_set1_epi32(2));
            __m256i m1 = _mm256_cmpgt_epi32(a1, _mm256_set1_epi32(2));
            __m256i m2 = _mm256_cmpgt_epi32(a2, _mm256_set1_epi32(2));
            a0 = _mm256_sub_epi32(a0, _mm256_and_si256(m0, three));
            a1 = _mm256_sub_epi32(a1, _mm256_and_si256(m1, three));
            a2 = _mm256_sub_epi32(a2, _mm256_and_si256(m2, three));
        }
    }

    /* 把 8 条通道的分离表示并成标量累加器 */
    {
        int32_t t0[8], t1[8], t2[8];
        int32_t acc = 0;
        int k;
        _mm256_storeu_si256((__m256i *)(void *)t0, a0);
        _mm256_storeu_si256((__m256i *)(void *)t1, a1);
        _mm256_storeu_si256((__m256i *)(void *)t2, a2);
        for (k = 0; k < 8; k++) {
            acc = gf27_add_scalar(acc, t0[k] + 3 * t1[k] + 9 * t2[k]);
        }
        /* 尾巴（n 不是 8 的倍数）走标量 */
        for (; j < n; j++) {
            acc = gf27_add_scalar(acc, gf27_mul_scalar(w[j], x[j], logT, expT));
        }
        return acc;
    }
}

#endif /* TRHA_X86 */

/* ------------------------------------------------------------------ */
/* 对外入口：按运行时能力派发                                           */
/* ------------------------------------------------------------------ */

/* 计算 Σ_j w[j] ⊗ x[j]（GF(27)），w/x 长度 n，logT/expT 为 Haskell 传进来的表。 */
int32_t trha_gf27_rowdot(const int32_t *w, const int32_t *x, int64_t n,
                         const int32_t *logT, const int32_t *expT)
{
#if TRHA_X86
    if (trha_gf27_has_avx2()) {
        return rowdot_avx2(w, x, n, logT, expT);
    }
#endif
    return rowdot_scalar(w, x, n, logT, expT);
}

/* 强制走标量路径（供"AVX2 ≡ 标量"对拍用）。 */
int32_t trha_gf27_rowdot_scalar_only(const int32_t *w, const int32_t *x, int64_t n,
                                     const int32_t *logT, const int32_t *expT)
{
    return rowdot_scalar(w, x, n, logT, expT);
}

/* ------------------------------------------------------------------ */
/* 27×27 连续乘积表 matmul（方向 A：1 次连续访存替代 6 次 gather）       */
/* ------------------------------------------------------------------ */

/* 构建 27×27 连续乘积表（常驻 L1：729 × 4 B ≈ 2.9 KB）。
 * 数学约定仍来自 Haskell 传入的 logT/expT —— 这里只是把它们「展开」成
 * 连续查找表，避免每次乘法做 6 次 gather（2×log + 1×exp + 3×分量）。 */
static void build_mul_table(int32_t (*t)[27], const int32_t *logT, const int32_t *expT)
{
    int32_t a, b, s;
    for (a = 0; a < 27; a++) {
        for (b = 0; b < 27; b++) {
            if (a == 0 || b == 0) {
                t[a][b] = 0;
                continue;
            }
            s = logT[a] + logT[b];
            if (s >= 26) {
                s -= 26;
            }
            t[a][b] = expT[s];
        }
    }
}

/* 构建 27×27 连续加法表（加法群 (Z/3)³：逐分量 mod 3，值域 0..26）。
 * 乘法走 t 表（乘法群 Z/26 周期，logT/expT 展开），加法走本表 ——
 * 「加法群 × 乘法群」联合周期 = 两张连续表，全程 0 除法。
 * （对照：gf27_add_scalar 每次加法 4 次整数除法，是 matmul 第二热点，
 *  见 SovereignGF27.hs gf27AddTable 同款做法。） */
static void build_add_table(int32_t (*g)[27])
{
    int32_t a, b;
    for (a = 0; a < 27; a++) {
        for (b = 0; b < 27; b++) {
            int32_t r0 = (a % 3 + b % 3) % 3;
            int32_t r1 = ((a / 3) % 3 + (b / 3) % 3) % 3;
            int32_t r2 = (a / 9 + b / 9) % 3;
            g[a][b] = r0 + 3 * r1 + 9 * r2;
        }
    }
}

static int32_t rowdot_table(const int32_t *w, const int32_t *x, int64_t n,
                            const int32_t (*t)[27], const int32_t (*g)[27])
{
    int32_t acc = 0;
    int64_t j;
    for (j = 0; j < n; j++) {
        acc = g[acc][t[w[j]][x[j]]];   /* 加法查 g 表：0 除法 */
    }
    return acc;
}

/* 方向 A：整块矩阵乘，用 27×27 连续表（乘法表 + 加法表，全程 0 除法）。
 * 输入/输出契约与 'trha_gf27_matmul' 完全一致；速度应显著优于 gather 版。
 * 数学 = 加法群×乘法群联合周期：乘查 mulTable（Z/26 周期），加查 addTable（(Z/3)³）。
 * 行间并行（OpenMP）：每行点积彼此独立，rows ≥ 几百时接近线性加速。 */
#include <omp.h>

int trha_gf27_matmul_table(int32_t *out,
                           const int32_t *w,
                           const int32_t *x,
                           int32_t rows, int32_t cols,
                           const int32_t *logT, const int32_t *expT)
{
    int32_t mulTable[27][27];
    int32_t addTable[27][27];
    int32_t r;
    if (out == NULL || w == NULL || x == NULL || rows < 0 || cols < 0) {
        return -1;
    }
    build_mul_table(mulTable, logT, expT);
    build_add_table(addTable);
#pragma omp parallel for schedule(static) if (rows >= 64)
    for (r = 0; r < rows; r++) {
        out[r] = rowdot_table(w + (int64_t)r * cols, x, cols, mulTable, addTable);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 整块矩阵乘（一次 C 调用算整块，绕开逐行 FFI 开销）                    */
/* ------------------------------------------------------------------ */

/* C = W ⊗ X：权重 W 行优先 [rows × cols]，激活 X 长 cols，输出 C 长 rows。
 *
 * 值域 / 契约与 gf27Rowdot 完全一致：
 *   W 元素、X 元素都是 0..26（GF(27)）；
 *   C[r] = GF(27) 行点积（同 'trha_gf27_rowdot'，包括 AVX2/标量派发与 logT/expT）。
 *
 * 为什么整块而不是逐行 FFI：
 *   Haskell 逐行调 'trha_gf27_rowdot' 时，每次都要跨 FFI 边界 + pokeArray 拷贝输入
 *   向量，1440 维行实测 81µs（其中 FFI/拷贝是大头）。整块一次调用把边界开销摊销到
 *   rows 行。权重保持**行优先连续布局**，在 C 内顺序遍历行 —— 缓存友好。
 *
 * 返回 0 成功；ptrs 为 NULL 或 rows<0 等非法输入返回 -1（不越界写）。
 */
int trha_gf27_matmul(int32_t *out,        /* 输出 [rows]（调用方分配） */
                     const int32_t *w,    /* 权重 [rows][cols]，行优先 */
                     const int32_t *x,    /* 激活 [cols] */
                     int32_t rows, int32_t cols,
                     const int32_t *logT, const int32_t *expT)
{
    int32_t r;
    if (out == NULL || w == NULL || x == NULL || rows < 0 || cols < 0) {
        return -1;
    }
#pragma omp parallel for schedule(static) if (rows >= 64)
    for (r = 0; r < rows; r++) {
        out[r] = trha_gf27_rowdot(w + (int64_t)r * cols, x, cols, logT, expT);
    }
    return 0;
}
