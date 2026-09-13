/*
 * cbits/wgpu_callback_shim.c —— 让 Haskell 能用 wgpu-native v29 的三个异步入口。
 *
 * 为什么不能用 Haskell 回调（两层原因）：
 *   1. WebGPU 回调的第二个参数是**按值** WGPUStringView，Haskell FFI 表达不了；
 *   2. 更要命：v29 的 wgpuInstanceWaitAny 尚未实现（src/unimplemented.rs 会 panic），
 *      只能自己驱动事件循环（wgpuInstanceProcessEvents）；而 ProcessEvents 会在
 *      **调用它的那个线程**上同步触发回调 —— 若那是 Haskell 的 FFI 调用栈，
 *      回调要进 Haskell 却拿不到 RTS 锁，会自己等自己。
 *      实测症状：C 侧打印了 "buffer_map cb status=..." 却始终不返回，
 *      Haskell 回调一次都没进（adapter/device 因回调来自 wgpu worker 线程而侥幸可用）。
 *
 * 因此本 shim **不调用任何 Haskell 回调**：trampoline 只把结果写进一个 C 侧槽位，
 * Haskell 侧轮询该槽位。跨语言传递的全是标量/指针。
 *
 * 用法（Haskell 侧）：
 *   trha_wgpu_request_adapter(inst, opts);
 *   while (!trha_wgpu_poll()) trha_wgpu_process_events(inst);   // 同时 threadDelay 让出
 *   status = trha_wgpu_last_status();  obj = trha_wgpu_last_object();
 *
 * 槽位是全局的 —— 本项目的 WebGPU 调用是**串行**的（一次只推进一个异步操作），
 * 所以不需要每请求上下文。
 */
#include <webgpu/webgpu.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

typedef struct {
    int32_t status; /* 0 = 成功（已归一化：v29 的 *Status 是 Success=0x1） */
    void   *object; /* adapter / device（按调用类型解释） */
    int     done;
} trha_slot;

static trha_slot g_slot = { -1, NULL, 0 };

static void slot_reset(void)
{
    g_slot.status = -1;
    g_slot.object = NULL;
    g_slot.done = 0;
}

static void bm_trampoline(WGPUMapAsyncStatus s, WGPUStringView m, void *u1, void *u2)
{
    (void)m; (void)u1; (void)u2;
    g_slot.status = (s == WGPUMapAsyncStatus_Success) ? 0 : (int32_t)s;
    g_slot.object = NULL;
    g_slot.done = 1;
}

static void ra_trampoline(WGPURequestAdapterStatus s, WGPUAdapter a, WGPUStringView m, void *u1, void *u2)
{
    (void)m; (void)u1; (void)u2;
    g_slot.status = (s == WGPURequestAdapterStatus_Success) ? 0 : (int32_t)s;
    g_slot.object = (void *)a;
    g_slot.done = 1;
}

static void rd_trampoline(WGPURequestDeviceStatus s, WGPUDevice d, WGPUStringView m, void *u1, void *u2)
{
    (void)m; (void)u1; (void)u2;
    g_slot.status = (s == WGPURequestDeviceStatus_Success) ? 0 : (int32_t)s;
    g_slot.object = (void *)d;
    g_slot.done = 1;
}

void trha_wgpu_request_adapter(WGPUInstance inst, const WGPURequestAdapterOptions *opts)
{
    WGPURequestAdapterCallbackInfo info;
    slot_reset();
    info.nextInChain = NULL;
    info.mode = WGPUCallbackMode_AllowSpontaneous;
    info.callback = ra_trampoline;
    info.userdata1 = NULL;
    info.userdata2 = NULL;
    (void)wgpuInstanceRequestAdapter(inst, opts, info);
}

void trha_wgpu_request_device(WGPUAdapter adapter, const WGPUDeviceDescriptor *desc)
{
    WGPURequestDeviceCallbackInfo info;
    slot_reset();
    info.nextInChain = NULL;
    info.mode = WGPUCallbackMode_AllowSpontaneous;
    info.callback = rd_trampoline;
    info.userdata1 = NULL;
    info.userdata2 = NULL;
    (void)wgpuAdapterRequestDevice(adapter, desc, info);
}

void trha_wgpu_buffer_map(WGPUBuffer buf, uint64_t mode, size_t off, size_t size)
{
    WGPUBufferMapCallbackInfo info;
    slot_reset();
    info.nextInChain = NULL;
    info.mode = WGPUCallbackMode_AllowSpontaneous;
    info.callback = bm_trampoline;
    info.userdata1 = NULL;
    info.userdata2 = NULL;
    (void)wgpuBufferMapAsync(buf, (WGPUMapMode)mode, off, size, info);
}

/* ------------------------------------------------------------------ */
/* uncaptured error：不让 wgpu-native 的默认处理器 abort 进程           */
/* ------------------------------------------------------------------ */

/* wgpu-native 默认遇到校验错误会 panic（直接 abort 进程）。这里在创建 device 时
 * 装上自己的回调，把错误存进槽位，Haskell 侧用 lastError 查询。 */

typedef struct {
    int32_t has;
    int32_t type;
    char    msg[1024];
} trha_err_slot;

static trha_err_slot g_err = { 0, 0, { 0 } };

static void error_trampoline(WGPUDevice const *device, WGPUErrorType type,
                             WGPUStringView message, void *u1, void *u2)
{
    (void)device; (void)u1; (void)u2;
    size_t n = 0;
    g_err.type = (int32_t)type;
    g_err.has = 1;
    if (message.data != NULL) {
        n = (message.length < sizeof(g_err.msg) - 1) ? message.length : sizeof(g_err.msg) - 1;
        memcpy(g_err.msg, message.data, n);
    }
    g_err.msg[n] = '\0';
}

/* 由 Haskell 侧调用来初始化一个 WGPUDeviceDescriptor（含错误回调）。
 * 之所以让 C 来填：该结构含内嵌的 WGPUQueueDescriptor 与两个 callbackInfo，
 * 在 Haskell 侧逐字段构造既冗长又易错位。size 由本文件提供，避免调用方猜。 */
size_t trha_wgpu_device_descriptor_size(void)
{
    return sizeof(WGPUDeviceDescriptor);
}

void trha_wgpu_device_descriptor_init(WGPUDeviceDescriptor *desc)
{
    memset(desc, 0, sizeof(*desc));
    desc->nextInChain = NULL;
    desc->label.data = NULL;
    desc->label.length = 0;
    desc->requiredFeatureCount = 0;
    desc->requiredFeatures = NULL;
    desc->requiredLimits = NULL;
    desc->uncapturedErrorCallbackInfo.nextInChain = NULL;
    desc->uncapturedErrorCallbackInfo.callback = error_trampoline;
    desc->uncapturedErrorCallbackInfo.userdata1 = NULL;
    desc->uncapturedErrorCallbackInfo.userdata2 = NULL;
}

int32_t     trha_wgpu_last_error_type(void)    { return g_err.has ? g_err.type : 0; }
const char *trha_wgpu_last_error_message(void) { return g_err.msg; }
void        trha_wgpu_clear_error(void)        { g_err.has = 0; g_err.type = 0; g_err.msg[0] = '\0'; }

int     trha_wgpu_poll(void)           { return g_slot.done; }
int32_t trha_wgpu_last_status(void)    { return g_slot.status; }
void   *trha_wgpu_last_object(void)    { return g_slot.object; }
void    trha_wgpu_process_events(WGPUInstance inst) { wgpuInstanceProcessEvents(inst); }
