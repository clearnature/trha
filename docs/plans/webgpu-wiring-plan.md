# WebGPU 后端接线计划（webgpu-wiring-plan）

> **日期**：2026-09-13（北京时间）
> **依据**：`docs/plans/code-docs-reconciliation.md` §7 待办 #8，处置方式经所有者裁定为 **C. 真正接线**（不是标注、也不是归档）
> **性质**：多批次工程。本文是该工程的**数据流程 + 原子分解 + 已完成项**，随进度更新。

---

## 0. 目标与非目标

| | 内容 |
|---|---|
| **目标** | `src/Infrastructure/WebGPU/**`（1344 行）真正进入构建并**在真实 GPU 后端上跑通**：Instance → Adapter → Device → Queue → Buffer → WGSL ComputePipeline → Dispatch → 读回结果 |
| **非目标** | 不追求性能对齐（那需要与 CPU 路径 benchmark 对拍）；不改动 CPU 三值推理路径 |
| **判据** | `cabal build` 链接 `libwgpu_native` 成功 + 一个 compute kernel（如 GF(27) 表构造或三值 matmul 片段）在 GPU 上算出的结果与 CPU 版**逐元素一致** |

---

## 1. 现状（实测，2026-09-13）

| 项 | 实测 |
|---|---|
| 代码规模 | 14 个 `.hs` + `README.md`，**1344 行**（最大 `WGSL.hs` 409、`Types.hs` 146、`ShaderLib.hs` 122） |
| 在构建中？ | **否** —— 不在任何 cabal 组件（`grep WebGPU --include=*.cabal` 无输出） |
| 被引用？ | **否** —— 全仓无 `import Infrastructure.WebGPU.*` |
| simulation 占位 | `Buffer.hs:49` → `Left (UnknownWebGPUError "Buffer mapping not implemented in simulation")`；全仓仅此 1 处 |
| **FFI 符号** | ❌ **`FFI.hs` 声明的 11 个符号是编造的**：`webgpu_create_device` / `webgpu_create_buffer` / … 在真实库中**一个都不存在**（`nm -D` 实测出现 0 次）。注释自认 "In production, these would link to wgpu-native or similar" |
| 真实 API 命名 | `wgpu` + 驼峰：`wgpuCreateInstance`、`wgpuDeviceCreateBuffer`、`wgpuDeviceCreateShaderModule`、`wgpuComputePassEncoderDispatchWorkgroups`、`wgpuQueueSubmit` … 标准 API 在 `webgpu.h`，native 扩展在 `wgpu.h` |
| 本机图形栈 | ✅ `libvulkan.so.1` (1.4.341) + `libEGL` 在位 → **可跑 Vulkan 后端**；无 `vulkaninfo`/`glxinfo`/`nvidia-smi` |
| 外部库可得性 | apt **无** wgpu-native（只有 `librust-wgpu-types-dev`，那是 Rust 类型库）；GitHub release 经代理可取（HTTP 200）；`cargo` 1.96 可编译 |

---

## 2. 数据流程图

### 2.1 现状（断链）

```
src/Infrastructure/WebGPU/**（1344 行）
   │
   ├─ WGSL.hs / ShaderLib.hs / Types.hs …   ← 纯 Haskell，真实可用
   ├─ Buffer.hs:49                          ← simulation 占位（map 未实现）
   └─ FFI.hs                                ← foreign import "webgpu_create_device" …
            │
            ✗ 符号不存在（nm -D libwgpu_native.so | grep 出现 0 次）
            ✗ 且整层不在任何 cabal 组件 → 从不参与编译
```

### 2.2 目标（接通后）

```
Haskell (trha)
  Infrastructure.WebGPU.FFI        ← 按 webgpu.h 真实签名绑定（重写）
        │  foreign import ccall "wgpuCreateInstance" 等
        ▼
  libwgpu_native.so                ← cabal: extra-libraries: wgpu_native
        │                             + extra-lib-dirs: <vendor>/lib
        │                             + include-dirs: <vendor>/include/webgpu
        ▼
  wgpu-core (Rust) → Vulkan (libvulkan.so.1, 本机已有)
        ▼
  GPU

初始化链（真实 WebGPU C API 的顺序，不可跳步）：
  wgpuCreateInstance
    → wgpuInstanceRequestAdapter        （或 wgpuInstanceEnumerateAdapters）
      → wgpuAdapterRequestDevice
        → wgpuDeviceGetQueue            ← Queue 由 Device 派生
          → wgpuDeviceCreateBuffer / wgpuDeviceCreateShaderModule(WGSL)
            → wgpuDeviceCreateComputePipeline
              → wgpuDeviceCreateCommandEncoder
                → wgpuCommandEncoderBeginComputePass
                  → wgpuComputePassEncoderSetPipeline / SetBindGroup
                    → wgpuComputePassEncoderDispatchWorkgroups
                  → wgpuComputePassEncoderEnd
                → wgpuCommandEncoderFinish
              → wgpuQueueSubmit → wgpuDevicePoll（同步等待）
          → wgpuBufferMapAsync + 回调 → 读回结果
```

**关键差异**：真实 API 的每个 `Create*` 都要**手写 struct 描述符指针**（`WGPUDeviceDescriptor`、`WGPUBufferDescriptor`、`WGPUComputePipelineDescriptor`…，字段数十个），而现有 `FFI.hs` 是 `Ptr ()` 占位的"简化签名" —— 所以不只是改名字，**还要补齐 struct/enum 绑定层**。

---

## 3. 原子分解

| ID | 原子 | 验收（可执行） | 状态 |
|---|---|---|---|
| **W1** | **库就位**：取 `wgpu-linux-x86_64-release.zip`（v29.0.1.1）→ 解出 `lib/libwgpu_native.so` + `include/webgpu/{webgpu.h,wgpu.h}`；用 `nm -D` 确认真实符号表 | `nm -D --defined-only lib/libwgpu_native.so \| grep -c webgpu_create_device` → **0**（证伪旧 FFI）；`grep -c wgpuCreateInstance` → **≥1** | ✅ **已完成（2026-09-13）** |
| **W2** | **struct/enum 绑定层**：从 `webgpu.h` 取 `WGPUDeviceDescriptor` / `WGPUBufferDescriptor` / `WGPUComputePipelineDescriptor` / `WGPUShaderModuleWGSLDescriptor` 等所需结构，写 `Structs.hs` + `Enums.hs`（Haskell `Storable` 实例） | 每个结构 sizeof/字段偏移与 C 头文件一致（用 `hsc2hs` 或手算 + 静态断言测试） | ◻ 待做 |
| **W3** | **重写 `FFI.hs`**：把 11 个编造符号换成真实签名（含 instance/adapter/device/queue 初始化链与 `WGPUStringView`/callback 类型） | `cabal build` 目标组件在 `-lwgpu_native` 下**链接成功**（无 undefined symbol） | ◻ 待做 |
| **W4** | **cabal 接线**：把 `Infrastructure.WebGPU.*` 加入组件（新 library 或并入 `trha-infra`），配 `extra-libraries: wgpu_native` / `extra-lib-dirs` / `include-dirs`；库放 `vendor/` 还是系统路径需定 | `cabal build all` EXIT=0 且组件被构建（不是被跳过） | ◻ 待做 |
| **W5** | **Buffer 真实现**：`wgpuDeviceCreateBuffer` + `wgpuBufferMapAsync`（异步回调 → MVar 桥接）替掉 `Buffer.hs:49` 的 simulation 占位 | 单元测试：写入 pattern → map 读回 → 逐元素一致 | ◻ 待做 |
| **W6** | **Compute 端到端**：用现成 `WGSL.hs`(409 行)/`ShaderLib.hs` 生成一个 kernel（建议从 GF(27) 表构造或三值 matmul 片段起步），跑完整 dispatch 链 | GPU 结果与 `SovereignGF27` 的 CPU 结果**逐元素一致** | ◻ 待做 |
| **W7** | **对拍与准入**：把 W6 的 kernel 纳入 `test/Spec.hs`（在无 GPU/无库时优雅 pending），并在 `docs/` 更新状态分档 | 有测试 + 文档与实测一致 | ◻ 待做 |

**依赖**：`W1 → W2 → W3 → W4 → W5 → W6 → W7`（严格串行；W2/W3 是主要工作量）

---

## 4. 决策点（需所有者拍板）

1. **库的落地方式**：`vendor/` 进仓（体积 +16MB，`libwgpu_native.a` 更大）／只留 `.so` 在系统路径（`/usr/local/lib` + `ldconfig`）／写进构建脚本按需下载？—— 影响可复现性与 CI。
2. **组件归属**：新建 `library trha-webgpu`，还是并入 `trha-infra`（后者会让人把 GPU 依赖当成内核基础依赖）？
3. **首批 kernel 范围**：只求"跑通链路的 hello-compute"，还是直接上 GF(27)/三值 matmul（后者才贴近项目愿景，但调错成本高）。
4. **CI**：GitHub runner 无 GPU，W6/W7 是否只在本地跑（`pending` 兜底）？

---

## 5. 复核命令

```bash
# W1：库与真实符号
ls /tmp/wgpu-native/lib /tmp/wgpu-native/include/webgpu
nm -D --defined-only /tmp/wgpu-native/lib/libwgpu_native.so | grep -c webgpu_create_device   # → 0（旧 FFI 是编造的）
nm -D --defined-only /tmp/wgpu-native/lib/libwgpu_native.so | grep -oE 'wgpu[A-Za-z]+' | sort -u | head

# 现状：整层不在构建、无引用
grep -rn "WebGPU" --include=*.cabal . | grep -v dist-newstyle      # → 无输出
grep -rn "import Infrastructure.WebGPU" --include=*.hs . | grep -v dist-newstyle   # → 无输出
sed -n '45,52p' src/Infrastructure/WebGPU/Buffer.hs

# 本机图形栈
ls /usr/lib/x86_64-linux-gnu/libvulkan* ; ls /usr/lib/x86_64-linux-gnu/libEGL*
```

---

## 6. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-09-13 | 初版：现状实测（1344 行不在构建、`FFI.hs` 符号经 `nm` 证伪、本机有 Vulkan）、数据流程图（现状断链 vs 目标接通含初始化链）、原子分解 W1–W7、决策点 4 项；**W1（库就位 + 符号表验证）已完成** |
