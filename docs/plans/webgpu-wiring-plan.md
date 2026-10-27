# WebGPU 后端接线计划（webgpu-wiring-plan）

> **日期**：2026-09-13（北京时间）
> **依据**：`docs/plans/code-docs-reconciliation.md` §7 待办 #8，处置方式经所有者裁定为 **C. 真正接线**
> **性质**：多批次工程。本文是该工程的**数据流程 + 原子分解 + 已完成项**，随进度更新。

---

## 0. 目标与约束

| | 内容 |
|---|---|
| **目标** | `src/webgpu/Infrastructure/WebGPU/**`（1344 行）真正进入构建并**在真实 GPU 后端上跑通**：Instance → Adapter → Device → Queue → Buffer → WGSL ComputePipeline → Dispatch → 读回 |
| **约束 1（强类型）** | 用 **GHC 强类型**重构绑定层：句子柄用不透明标签类型 + `Handle`/`Nullable` typeclass（见 `src/webgpu/Infrastructure/WebGPU/Raw/Types.hs`），**不沿用现状的裸 `Ptr ()`** —— 裸指针下 `Device`/`Buffer`/`Queue` 可互传，错用只在运行时段错误暴露 |
| **约束 2（第三方代码进仓）** | 外部库与参考源码**一律复制进仓库 `3rdparty/`**，**不在仓库外引用**（不再依赖 `/data/trit/BitNet/...` 路径） |
| **约束 3（参考实现）** | 流程与 WGSL 参考 `3rdparty/llama-webgpu/`（**旧写作 `ref-llama.cpp-ggml-webgpu/`，实际入库名不同**）；但**其代码不可照搬** —— 它用 C++ 封装头 `<webgpu/webgpu_cpp.h>`（`wgpu::Instance` / `device.createBuffer(...)`），我们走 Haskell FFI（C ABI），权威来源是 `3rdparty/wgpu-native/include/webgpu/webgpu.h` |
| **非目标** | 不追求性能对齐；不改动 CPU 三值推理路径 |
| **判据** | `cabal build` 链接 `libwgpu_native` 成功 + 一个 compute kernel 的 GPU 结果与 CPU 版**逐元素一致** |

---

## 1. 现状（实测，2026-09-13）

| 项 | 实测 |
|---|---|
| 代码规模 | 14 个 `.hs` + `README.md`，**1344 行**（最大 `WGSL.hs` 409、`Types.hs` 146、`ShaderLib.hs` 122） |
| 在构建中？ | ~~**否** —— 不在任何 cabal 组件~~ ⚠️ **这是 2026-09-13 的快照，已过期**：同日之后 W1–W7 跑通，已有 `library trha-webgpu`（`trha.cabal:222`）。以 §7/§8 为准 |
| 被引用？ | **否** —— 全仓无 `import Infrastructure.WebGPU.*` |
| simulation 占位 | `Buffer.hs:49` → `Left (UnknownWebGPUError "Buffer mapping not implemented in simulation")`；全仓仅此 1 处 |
| **FFI 符号** | ❌ **`FFI.hs` 声明的 11 个符号是编造的**：`webgpu_create_device` 等**在真实库中一个都不存在**（`nm -D` 实测出现 **0** 次）。注释自认 "In production, these would link to wgpu-native or similar" |
| 真实 API 命名 | `wgpu` + 驼峰（`wgpuCreateInstance`、`wgpuDeviceCreateBuffer`…）；标准 API 在 `webgpu.h`，native 扩展在 `wgpu.h` |
| **API 版本风格** | wgpu-native **v29.0.1.1** 用 `WGPUStringView`（非 `const char*`）+ `WGPUCallbackMode` + `*CallbackInfo` 结构；**`wgpuDevicePoll` 已不存在**（0 命中），同步等待改走 callback mode |
| 本机图形栈 | ✅ `libvulkan.so.1` (1.4.341) + `libEGL` 在位 → **可跑 Vulkan 后端**；无 `vulkaninfo`/`glxinfo`/`nvidia-smi` |

---

## 2. `3rdparty/` 布局（已落位）

```
3rdparty/
├── wgpu-native/                        9.3M   ← 运行时库（v29.0.1.1）
│   ├── lib/libwgpu_native.so           8.9M
│   └── include/webgpu/{webgpu.h,wgpu.h} 312K
├── llama-webgpu/                       816K   ← 参考实现（llama.cpp 59237bfbb 的 ggml/src/ggml-webgpu）
│   ├── ggml-webgpu.cpp                 4262 行（C++ API 用法；流程可参考，代码不可照搬）
│   ├── ggml-webgpu-shader-lib.hpp      2805 行
│   ├── pre_wgsl.hpp                     778 行
│   ├── CMakeLists.txt
│   └── wgsl-shaders/                    41 个 WGSL（**可复用**：WGSL 跨 API 通用）
└── llama-vulkan/                        ← Vulkan 后端源码（按所有者指示入库，作后端对照）
    ├── ggml-vulkan.cpp
    ├── vulkan-shaders/ · cmake/ · CMakeLists.txt
```

> **目录名更正（2026-09-17）**：本节原写作 `ref-llama.cpp-ggml-webgpu/`，实际入库名是
> **`llama-webgpu/`**（本文 §7/§8 用的就是正确名字）。以 `ls 3rdparty/`
> → `llama-vulkan  llama-webgpu  wgpu-native` 为准。

**未入库**：`libwgpu_native.a`（静态库，**50M**）—— 动态链接只需 `.so`；若将来要走 README 所述"静态编译（Alpine+musl）"再取回（同一条下载命令，版本 v29.0.1.1）。

来源记录：wgpu-native `v29.0.1.1`（release zip，15.9M）；llama.cpp commit `59237bfbb`。

---

## 3. 数据流程图

### 3.1 现状（断链）

```
src/webgpu/Infrastructure/WebGPU/**（1344 行）
   ├─ WGSL.hs / ShaderLib.hs / Types.hs …   ← 纯 Haskell，真实可用
   ├─ Buffer.hs:49                          ← simulation 占位（map 未实现）
   └─ FFI.hs                                ← foreign import "webgpu_create_device" …
            ✗ 符号不存在（nm -D | grep → 0 次）
            ✗ 整层不在任何 cabal 组件 → 从不参与编译   ← ⚠️ 2026-09-13 快照，已过期（见 §7）
```

### 3.2 目标（接通后）

```
Haskell (trha)
  Infrastructure.WebGPU.Raw.Types    ← 强类型句柄（已完成：12 个不透明标签 + Handle/Nullable）
  Infrastructure.WebGPU.Raw.Enums    ← 枚举（WGPUStringView / BufferUsage / MapMode / CallbackMode …）
  Infrastructure.WebGPU.Raw.Structs  ← 描述符 Storable（sizeof/偏移由 hsc2hs 从真头文件取）
  Infrastructure.WebGPU.Raw.FFI      ← foreign import ccall "wgpuCreateInstance" 等真实符号
        │
        ▼
  3rdparty/wgpu-native/lib/libwgpu_native.so   ← cabal: extra-libraries: wgpu_native
        │                                          extra-lib-dirs: 3rdparty/wgpu-native/lib
        │                                          include-dirs:   3rdparty/wgpu-native/include/webgpu
        ▼
  wgpu-core (Rust) → Vulkan (libvulkan.so.1)  →  GPU

初始化链（真实 C API 顺序，不可跳步）：
  wgpuCreateInstance(descriptor?)
    → wgpuInstanceRequestAdapter(instance, options, callbackInfo)   ← v29：回调式（也有 Sync 变体）
      → wgpuAdapterRequestDevice(adapter, descriptor, callbackInfo)
        → wgpuDeviceGetQueue(device)
          → wgpuDeviceCreateBuffer / wgpuDeviceCreateShaderModule(WGSL)
            → wgpuDeviceCreateBindGroupLayout → wgpuDeviceCreatePipelineLayout
              → wgpuDeviceCreateComputePipeline
                → wgpuDeviceCreateCommandEncoder
                  → wgpuCommandEncoderBeginComputePass
                    → wgpuComputePassEncoderSetPipeline / SetBindGroup
                      → wgpuComputePassEncoderDispatchWorkgroups
                    → wgpuComputePassEncoderEnd
                  → wgpuCommandEncoderFinish
                → wgpuQueueSubmit
          → wgpuBufferMapAsync + 回调 → 读回
```

**关键差异**：真实 API 的每个 `Create*` 都要传 **struct 描述符指针**（`WGPUDeviceDescriptor` 等），而现有 `FFI.hs` 是 `Ptr ()` 占位的"简化签名" —— 不只是改名字，**还要补齐 struct/enum 绑定层**（用 `hsc2hs` 的 `#{size}` / `#{offset}` 让 GHC 直接从头文件取值，避免手算偏移出错）。

---

## 4. 原子分解

| ID | 原子 | 验收（可执行） | 状态 |
|---|---|---|---|
| **W1** | **库就位 + 参考进仓**：取 wgpu-native v29.0.1.1 → `3rdparty/wgpu-native/`；复制 llama.cpp ggml-webgpu → `3rdparty/llama-webgpu/`；`nm -D` 确认符号表 | `nm -D ... \| grep -c webgpu_create_device` → **0**；`grep -c wgpuCreateInstance` → **≥1**；两个 `3rdparty/` 目录存在 | ✅ **已完成** |
| **W2a** | **强类型句柄层**：12 个不透明标签 + `Handle`/`Nullable` typeclass，构造子不导出 | 编译通过 + 类型不可混用（`Device` 传给要 `Buffer` 的函数应**编译失败**） | ✅ **代码已写**（`Raw/Types.hs`，待 W4 接入组件后编译验证） |
| **W2b** | **枚举与描述符绑定**：`Raw/Enums.hs` + `Raw/Structs.hsc`（`hsc2hs` 取 `#{size}/#{offset}`） | 每个结构的 `sizeOf`/字段偏移与 C 头一致（静态断言测试） | ◻ 待做 |
| **W3** | **真实 FFI**：`Raw/FFI.hs` 按 `webgpu.h` 真实签名绑定（初始化链 + `WGPUStringView` + `*CallbackInfo`） | 组件在 `-lwgpu_native` 下**链接成功**（无 undefined symbol） | ◻ 待做 |
| **W4** | **cabal 接线**：新建 `library trha-webgpu`（**已裁定**），配 `extra-libraries/include-dirs/extra-lib-dirs` 指向 `3rdparty/wgpu-native/` | `cabal build trha-webgpu` EXIT=0（先不含外部库跑通 W2a，再加库跑通 W3） | ◻ 待做（先做 W2a 部分） |
| **W5** | **Buffer 真实现**：`wgpuDeviceCreateBuffer` + `wgpuBufferMapAsync`（回调 → `MVar` 桥接）替掉 `Buffer.hs:49` 占位 | 写入 pattern → map 读回 → 逐元素一致 | ◻ 待做 |
| **W6** | **hello-compute 端到端**（**已裁定**先行）：最小 compute（写入 → dispatch → 读回比对）跑通链路；之后再换 GF(27)/三值 kernel | GPU 结果与 CPU 参考一致 | ◻ 待做 |
| **W7** | **测试与文档**：纳入测试套件（无 GPU/无库时**优雅 pending**）；文档同步实测状态 | 有测试 + 文档与实测一致 | ◻ 待做 |

**依赖**：`W1 → W2a → W4(部分) → W2b → W3 → W4(完整) → W5 → W6 → W7`
（W2a + 不含外部库的 W4 先跑，可尽早在无 C 库依赖的情况下验证强类型层本身是对的。）

---

## 5. 已裁定事项

| 问题 | 裁定 |
|---|---|
| 库的落地方式 | **`3rdparty/` 进仓**（不在仓库外引用）；`.so` + 头文件先入，`.a`(50M) 暂缓 |
| 组件归属 | **新建 `library trha-webgpu`**（不并入 `trha-infra`，避免 GPU 依赖污染内核基础层） |
| 首批 kernel 范围 | **先 hello-compute 跑通链路**，再上 GF(27)/三值 |
| 重构方式 | **GHC 强类型**（不透明标签 + typeclass；不用裸 `Ptr ()`） |
| CI | 无 GPU 的 runner 上相关用例 `pending` 兜底 |

---

## 6. 复核命令

```bash
# 3rdparty 布局与来源
find 3rdparty -maxdepth 2 -type d | sort
nm -D --defined-only 3rdparty/wgpu-native/lib/libwgpu_native.so | grep -c webgpu_create_device   # → 0（旧 FFI 是编造的）
nm -D --defined-only 3rdparty/wgpu-native/lib/libwgpu_native.so | grep -oE 'wgpu[A-Za-z]+' | sort -u | head
ls 3rdparty/llama-webgpu/wgsl-shaders | wc -l    # → 41

# 现状：整层不在构建、无引用
grep -rn "WebGPU" --include=*.cabal . | grep -v dist-newstyle
grep -rn "import Infrastructure.WebGPU" --include=*.hs . | grep -v dist-newstyle

# 本机图形栈
ls /usr/lib/x86_64-linux-gnu/libvulkan* ; ls /usr/lib/x86_64-linux-gnu/libEGL*
```

---

## 7. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-09-13 | 初版：现状实测（1344 行不在构建、`FFI.hs` 符号经 `nm` 证伪、本机有 Vulkan）、数据流程图、原子分解 W1–W7、决策点 4 项；**W1 完成** |
| 2026-09-17 | **§2 目录名更正**：原写 `3rdparty/ref-llama.cpp-ggml-webgpu/`，实际入库名是 `llama-webgpu/`（并补上 `llama-vulkan/`）。同时补记：本层**仍未接入生产推理路径**（`grep -rn "Infrastructure.WebGPU" --include=*.hs src/ | grep -v "^src/webgpu/Infrastructure/WebGPU/"` → 无输出），引用只出现在 `benchmarks/`、`test/webgpu/`、`test/cpu/negative/` |
| 2026-09-13 | 所有者裁定：库入 `3rdparty/`（不在仓库外引用）／新建 `library trha-webgpu`／首批先 hello-compute／**用 GHC 强类型重构**。据此：库与参考源码落位 `3rdparty/`；新写 `Raw/Types.hs`（12 个不透明标签 + `Handle`/`Nullable`，构造子不导出）＝ W2a；确认 llama.cpp 参考用的是 **C++ API（`webgpu_cpp.h`）**、代码不可照搬（WGSL 与流程可复用）；补齐 v29 API 风格（`WGPUStringView` + `*CallbackInfo`，`wgpuDevicePoll` 已移除） |

---

## 7. 实测记录（2026-09-13）：W1–W6 已跑通

`trha-webgpu-compute` 在 AMD/Vulkan（radv）上输出：

```
输入: [1,2,3,4]   期望: [1,4,9,16]   实际: [1,4,9,16]
✓ GPU 结果与 CPU 参考答案逐元素一致
```

| 步骤 | 状态 | 说明 |
|---|---|---|
| W1 库与参考进仓 | ✅ | `3rdparty/wgpu-native`（v29.0.1.1）、`3rdparty/llama-webgpu`（ggml-webgpu 参考）、`3rdparty/llama-vulkan`（Vulkan 后端源码，按所有者指示） |
| W2a 强类型句柄 | ✅ | 12 个不透明标签 + Handle/Nullable；负面测试证明类型不可混用 |
| W2b 枚举/描述符 | ✅ | 值经 hsc2hs 从真头文件求值，偏移同理 |
| W3 FFI 绑定 | ✅ | 19 个真实符号（含 CopyBufferToBuffer），均由 nm 核实存在 |
| W4 cabal 接线 | ✅ | extra-libraries + extra-lib-dirs-static；cabal 规范升到 3.8 |
| W5/W6 端到端 | ✅ | 完整 dispatch 链 + 读回对拍通过 |

### 踩过的坑（照文档写会踩的）

1. **编辑 .hsc 后 hsc2hs 可能不重跑**（cabal 缓存了预处理结果，touch 无效）→ 删掉该组件的 dist-newstyle 产物才会重新生成。
2. **cabal 的 extra-lib-dirs 只接受绝对路径或 pkgroot 相对路径**；`extra-lib-dirs-static` 需 Cabal 规范 ≥3.8；而动态目录只能由 extra-lib-dirs（绝对）提供 → 本机绝对路径放 `cabal.project.local`（不入仓）。
3. **Cabal 规范 ≥3.4 后同包内部库依赖要写 `trha:trha-xxx`**，否则报 unknown package。
4. **会回调进 Haskell 的 foreign import 必须用 safe**，unsafe 会以 `schedule: re-entered unsafely` 中止。
5. **v29 的 wgpuInstanceWaitAny 未实现**（src/unimplemented.rs 直接 panic）。
6. **让 C 回调进 Haskell 会死锁**：回调在 ProcessEvents 的**调用线程**上同步触发，而该线程正处在 FFI 栈里，拿不到 RTS 锁 → 改为「C 侧槽位 + Haskell 轮询」。
7. **v29 的 \*Status 枚举 Success = 0x1**，不是 0（按 0 判会把成功误判为失败）。
8. **MAP_READ 只能与 COPY_DST 搭配、不能叠 STORAGE** → 两个 buffer + CopyBufferToBuffer 搬运。
9. **描述符必须先清零**（含未填的内嵌结构，如 bind group layout entry 的 sampler/texture/storageTexture）。
10. 运行时需 `LD_LIBRARY_PATH=$PWD/3rdparty/wgpu-native/lib`（尚未设 rpath）。

---

## 8. 旧层处置与新高层（2026-09-13）

### 旧层：已归档 —— 结论是"没有可接入的逻辑"

所有者最初裁定「D. 重写接入新层」。逐文件读完后发现旧层（14 文件 1344 行）**不是**
"待接线的分层 API"，而是一组空壳：

| 位置 | 代码 | 事实 |
|---|---|---|
| `Backend.hs` `executeCompute` | `threadDelay 1000; return (Right ())` | 拿 sleep 假装算过 |
| `Buffer.hs` `createBuffer` | `let bufferId = 1  -- Would generate unique ID in production` | 假 ID，恒为 1 |
| `Buffer.hs` `mapBuffer` | `Left (UnknownWebGPUError "… simulation")` | 占位 |
| `Compute.hs` `matrixMultiply` | 只 `createBuffer` 就返回 | **从不 dispatch** |
| `FFI.hs` | `webgpu_create_*` 等 11 个符号 | 真实库 `nm` 实测 0 命中 |

唯一"真"的 `WGSL.hs`/`ShaderLib.hs` 只是 llama.cpp shader 的 f32 转写，而原始 `.wgsl`
已在 `3rdparty/llama-webgpu/wgsl-shaders/`（41 个文件）。

→ 按所有者确认的方案 A 执行：**新写高层 + 归档旧层**。旧层移至
`archive/webgpu-legacy/`，含 README（空壳证据 / 取代关系表 / 取回方式与警告）。

### 新高层（已建，真机验证）

| 模块 | 职责 | 状态 |
|---|---|---|
| `Infrastructure.WebGPU.Context` | instance → adapter → device → queue 生命周期 | ✅ |
| `Infrastructure.WebGPU.Buffer` | `GpuBuffer` 创建/上传/读回；封装 `MAP_READ` 的「两 buffer + CopyBufferToBuffer」两步法 | ✅ |
| `Infrastructure.WebGPU.Kernel` | WGSL → ShaderModule → BindGroup(Layout) → PipelineLayout → Pipeline → dispatch | ✅ |

效果：`benchmarks/webgpu/Compute.hs` 由 231 行降到 50 行，低层细节（描述符/指针偏移/
事件泵/usage 组合）不再出现在调用点。

### 仍待做

| 项 | 说明 |
|---|---|
| `Profile` | 真实 GPU 计时（旧层是 `threadDelay` 假计时） |
| `Error` | 错误类型 + **uncaptured error** 回调 —— 目前任何 WebGPU 校验错误都会让 wgpu-native 的默认处理器直接 abort 进程（调试期靠它的消息定位问题，但库化后需要自己接管） |
| rpath | 现在靠 `LD_LIBRARY_PATH`；可在 cabal 加 `-optl-Wl,-rpath,…` 免去 |
| 三值 / GF(27) kernel | 当前跑的是普通 u32 kernel；愿景所需的 kernel 需另写 WGSL 并与 `SovereignGF27` 对拍 |
| 测试纳入 | 现以 `trha-webgpu-compute` 作冒烟；可加 hspec（无 GPU 时 pending 兜底） |

---

## 9. T1–T4 完成（2026-09-13）

| 项 | 状态 |
|---|---|
| T1 GF(27) matmul kernel | ✅ 与 CPU `gf27Matmul` 逐元素一致（64×64、512×512 两档） |
| T2 Profile 真实计时 | ✅ 墙钟（`GHC.Clock.getMonotonicTime`，base 自带） |
| T3 rpath | ✅ `cabal.project.local` 的 `-optl-Wl,-rpath,…`，不再需要 `LD_LIBRARY_PATH` |
| T4 独立 hspec 套件 | ✅ `trha-webgpu-test`（2 例；无 GPU 时 pending） |

### 参考计时：GPU vs CPU（AMD/Vulkan/radv）—— **仅记录，不作判据**

> 判据见 `docs/plans/verification-criteria.md`：正确性以数学/理论为准，性能是环境标量。

| 规模 | GPU（含提交往返） | CPU（`gf27Matmul`） | 比值 |
|---|---|---|---|
| 64×64 | 3.73 ms | 1.36 ms | GPU **慢 2.7×** |
| 512×512 | **3.61 ms** | 25.86 ms | GPU **快 7.2×** |

**GPU 时间几乎不随规模变化** —— 3.6 ms 是**固定开销**（提交往返 + 映射读回 + 事件泵轮询），
与计算量无关。交叉点约 **300×300**：小于它不划算，大于它 GPU 才开始显现优势。

⚠️ 测的是**墙钟**（含主机侧开销），**不是**纯 GPU 内核时间；纯内核计时需 GPU 时间戳查询（待做）。

### 又两条"照文档写会中"

11. **具体尺寸的条目数组不能用固定 `allocaBytes`** —— `BindGroupLayoutEntry` 约 128 字节，
    3 个就越界写，症状是 wgpu-native 报一个**毫不相干**的
    `invalid sampler binding type for sampler binding layout at binding 2`。
    只要 2 个 entry 就不会暴露（手写版正是因此蒙对，换成高层抽象后才炸）。
12. **Haskell 惰性会让计时撒谎** —— `let want = …` 只构造 thunk，CPU 计时一度报
    `4.2e-5 ms`（比真实快 5 个数量级）。强制求值：`evaluate (foldl' (+) 0 want)`。

### 已知缺口（对抗自检的结论，**未验证项如实列出**）

- **hspec 的 pending 分支未实测**：本机有 GPU，`createContext` 失败 → `pendingWith`
    这条路径只有代码逻辑，没跑过（CI 无 GPU 时才会走到）。
- **Profile 只有 2 个数据点**，且含固定开销；"交叉点 300" 是**合理外推**而非测量。
- **新发现待处置**：`src/llm/Infrastructure/CPU/Backend.hs:52,59` 里有与已归档旧 WebGPU 层
    **同款**的 `threadDelay 1000` / `threadDelay 100` 假计时 —— 那是另一个"看起来在算、
    其实在睡"的位置，需要定夺（它是否在构建路径上、是否该照旧 WebGPU 层处理）。
- **未做**：纯 GPU 内核计时、tile + 共享内存优化（路径 B）、更大规模的 matmul、
    三值（Trit）输入的量化/打包形态（当前权重按 u32 传 trit 值）。
