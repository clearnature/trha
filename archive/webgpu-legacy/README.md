# 归档：旧 WebGPU 层（`Infrastructure.WebGPU.*`）

**归档日期**：2026-09-13（北京时间）
**归档决定**：所有者裁定「A. 新写高层 + 归档旧层」
**原路径**：`src/Infrastructure/WebGPU/*.hs`（14 个文件 / 1344 行）
**取代者**：`src/Infrastructure/WebGPU/Raw/**`（强类型真实绑定，已真机跑通）+ 基于它的高层模块

---

## 为什么是"归档"而不是"接线"

所有者最初裁定「重写接入新层」。逐文件读完之后，实测结论是**这一层没有可接入的逻辑** ——
它不是"待接线的分层 API"，而是一组**空壳**：

| 位置 | 代码 | 事实 |
|---|---|---|
| `Backend.hs` `executeCompute` | `threadDelay 1000; return (Right ())` | 拿 sleep 假装算过 |
| `Backend.hs` `synchronizeDevice` | `threadDelay 100; putStrLn "Device synchronized"` | 同上 |
| `Buffer.hs` `createBuffer` | `let bufferId = 1  -- Would generate unique ID in production` | 假 ID，恒为 1 |
| `Buffer.hs` `mapBuffer` | `Left (UnknownWebGPUError "… simulation")` | 占位 |
| `Buffer.hs` `bufferData` | `return BS.empty` | 永远返回空 |
| `Compute.hs` `matrixMultiply` 等 | 只 `createBuffer` 就返回 | **从不 dispatch** |
| `FFI.hs` | `foreign import ccall "webgpu_create_device"` 等 11 个符号 | **真实库中一个都不存在**（`nm -D` 0 命中） |

唯一"真"的是 `WGSL.hs` / `ShaderLib.hs` 里的 shader 字符串 —— 但它们只是 **llama.cpp shader
的转写**（`mul_mat_vec` / `soft_max` / `rms_norm_mul` / `rope` / `ssm_conv` …，全是 `f32`），
而**更权威的原始 `.wgsl` 已在** `3rdparty/llama-webgpu/wgsl-shaders/`（41 个文件）；
且它们与项目愿景（三值 / GF(27)）无关。

## 取代关系

| 旧层（本目录） | 新层 |
|---|---|
| `Types.hs` (146) | `Raw/Types.hs` —— 12 个不透明标签 + `Handle`/`Nullable`，句柄类型不可混用 |
| `FFI.hs` (69，编造符号) | `Raw/FFI.hs` —— 19 个真实符号（`nm` 已核实） |
| `Buffer.hs` (60，假 ID/占位) | `Raw/Structs.hsc` + 高层 `Buffer` 模块（创建/上传/读回） |
| `Device.hs` / `Shader.hs` / `Command.hs` (152) | `Raw/FFI.hs` + `Raw/Async.hs`（含 C shim：按值 struct 转换与事件泵） |
| `Compute.hs` (64，不 dispatch) | 高层 `Kernel` 模块（真 dispatch） |
| `Backend.hs` (68，threadDelay) | 高层 `Context` / `Run` |
| `Profile.hs` (75) | 待做（真实计时，而非 sleep） |
| `Error.hs` (50) | 待做（错误类型 + uncaptured error 回调） |
| `WGSL.hs` / `ShaderLib.hs` (531) | `3rdparty/llama-webgpu/wgsl-shaders/`（原始 `.wgsl`，更权威） |
| `Main.hs` / `Test.hs` (129) | `benchmarks/webgpu/{HelloCompute,Compute}.hs`（已真机跑通） |

## 如何取回

```bash
git mv archive/webgpu-legacy/*.hs src/Infrastructure/WebGPU/    # 注意别覆盖 Raw/
```

Git 历史同样可用：`git log --follow archive/webgpu-legacy/Backend.hs`。

**取回前请先读上面那张表** —— 这些文件的实现是占位（`threadDelay` / 假 ID / `BS.empty`），
直接接线**不会**得到可用的 GPU 计算。
