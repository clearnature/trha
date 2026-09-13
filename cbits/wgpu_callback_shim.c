/*
 * cbits/wgpu_callback_shim.c —— 让 Haskell 能接 WebGPU 的异步回调。
 *
 * 为什么需要这一层：
 *   wgpu-native v29 的三个异步入口（wgpuInstanceRequestAdapter /
 *   wgpuAdapterRequestDevice / wgpuBufferMapAsync）都要求传 *CallbackInfo，
 *   其中的 callback 函数指针第二个参数是 **按值** 的 WGPUStringView：
 *
 *     typedef void (*WGPUBufferMapCallback)(WGPUMapAsyncStatus status,
 *                                           WGPUStringView message,   // ← 按值 struct
 *                                           void* userdata1, void* userdata2);
 *
 *   而 Haskell 的 FFI **不支持按值传 struct**，所以 Haskell 无法直接实现这个回调。
 *   这里用一个 C 蹦床（trampoline）把 WGPUStringView 拆成 (data 指针, length)
 *   两个标量再回调 Haskell —— 结构只在 C 侧出现，Haskell 侧全是标量/指针。
 *
 *   另外 WGPUFuture / WGPUFutureWaitInfo 也是 struct，本 shim 一律以 uint64_t
 *   （future.id）与标量出参形式对外，避免 Haskell 侧再碰按值 struct。
 *
 * 约定：Haskell 侧回调统一为 (status, msgPtr, msgLen, userdata) 四参，
 *       其中 msgPtr/msgLen 来自 WGPUStringView（可能为 NULL/0）。
 */

#include <webgpu/webgpu.h>
#include <stdint.h>
#include <stddef.h>

/* ------------------------------------------------------------------ */
/* Haskell 侧回调类型（全标量/指针，规避按值 struct）                    */
/* ------------------------------------------------------------------ */

typedef void (*trha_buffer_map_cb)(int32_t status, const char *msg, size_t msgLen, void *userdata);
typedef void (*trha_request_adapter_cb)(int32_t status, WGPUAdapter adapter,
                                        const char *msg, size_t msgLen, void *userdata);
typedef void (*trha_request_device_cb)(int32_t status, WGPUDevice device,
                                       const char *msg, size_t msgLen, void *userdata);

/* ------------------------------------------------------------------ */
/* 蹦床：把按值 WGPUStringView 拆成 (指针, 长度)                        */
/* ------------------------------------------------------------------ */

static void trha_bm_trampoline(WGPUMapAsyncStatus status, WGPUStringView message,
                               void *userdata1, void *userdata2)
{
    (void)userdata2;
    trha_buffer_map_cb cb = (trha_buffer_map_cb)userdata1;
    if (cb) {
        cb((int32_t)status, message.data, message.length, NULL);
    }
}

static void trha_ra_trampoline(WGPURequestAdapterStatus status, WGPUAdapter adapter,
                               WGPUStringView message, void *userdata1, void *userdata2)
{
    (void)userdata2;
    trha_request_adapter_cb cb = (trha_request_adapter_cb)userdata1;
    if (cb) {
        cb((int32_t)status, adapter, message.data, message.length, NULL);
    }
}

static void trha_rd_trampoline(WGPURequestDeviceStatus status, WGPUDevice device,
                               WGPUStringView message, void *userdata1, void *userdata2)
{
    (void)userdata2;
    trha_request_device_cb cb = (trha_request_device_cb)userdata1;
    if (cb) {
        cb((int32_t)status, device, message.data, message.length, NULL);
    }
}

/* ------------------------------------------------------------------ */
/* 对外接口：返回 future.id（uint64_t），不开 struct                    */
/* ------------------------------------------------------------------ */

/* 用 WGPUCallbackMode_WaitAnyOnly：回调只在 wgpuInstanceWaitAny 里触发，
 * 因此"发起 → WaitAny → 取结果"在单线程是确定的。 */
uint64_t trha_wgpu_instance_request_adapter(WGPUInstance instance,
                                            const WGPURequestAdapterOptions *options,
                                            trha_request_adapter_cb cb)
{
    WGPURequestAdapterCallbackInfo info;
    info.nextInChain = NULL;
    info.mode = WGPUCallbackMode_WaitAnyOnly;
    info.callback = trha_ra_trampoline;
    info.userdata1 = (void *)cb;
    info.userdata2 = NULL;
    return wgpuInstanceRequestAdapter(instance, options, info).id;
}

uint64_t trha_wgpu_adapter_request_device(WGPUAdapter adapter,
                                          const WGPUDeviceDescriptor *descriptor,
                                          trha_request_device_cb cb)
{
    WGPURequestDeviceCallbackInfo info;
    info.nextInChain = NULL;
    info.mode = WGPUCallbackMode_WaitAnyOnly;
    info.callback = trha_rd_trampoline;
    info.userdata1 = (void *)cb;
    info.userdata2 = NULL;
    return wgpuAdapterRequestDevice(adapter, descriptor, info).id;
}

uint64_t trha_wgpu_buffer_map_async(WGPUBuffer buffer, uint64_t mode,
                                    size_t offset, size_t size,
                                    trha_buffer_map_cb cb)
{
    WGPUBufferMapCallbackInfo info;
    info.nextInChain = NULL;
    info.mode = WGPUCallbackMode_WaitAnyOnly;
    info.callback = trha_bm_trampoline;
    info.userdata1 = (void *)cb;
    info.userdata2 = NULL;
    return wgpuBufferMapAsync(buffer, (WGPUMapMode)mode, offset, size, info).id;
}

/* 阻塞等待一个 future（内部构造 WGPUFutureWaitInfo，Haskell 侧只见标量）。
 * 返回 WGPUWaitStatus 的原始值。timeoutNS 传 UINT64_MAX 表示不限时。 */
int32_t trha_wgpu_instance_wait_any(WGPUInstance instance, uint64_t futureId,
                                    uint64_t timeoutNS)
{
    WGPUFutureWaitInfo waitInfo;
    waitInfo.future.id = futureId;
    waitInfo.completed = WGPU_FALSE;
    WGPUWaitStatus st = wgpuInstanceWaitAny(instance, (size_t)1, &waitInfo, timeoutNS);
    return (int32_t)st;
}
