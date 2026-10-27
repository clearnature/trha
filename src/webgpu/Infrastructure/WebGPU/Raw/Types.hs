{-# LANGUAGE TypeFamilies #-}

-- | WebGPU 对象的**强类型句柄层**（Raw = 贴近 C API，不加安全/便利包装）。
--
-- == 为什么要有这一层
--
-- 现状 @src\/Infrastructure\/WebGPU\/**@ 用裸 @Ptr ()@ 承载所有 WebGPU 对象，
-- 于是 @Device@、@Buffer@、@Queue@ 可以互传而不报错 —— 错用要等到运行时段错误
-- 才暴露，且 FFI 边界上无从审查。本模块给每个对象类型一个**独立的不透明标签**
-- （@*OD@ = Object Descriptor），句柄只持有指向自己标签的 @Ptr@：
--
-- > newtype Device = Device (Ptr DeviceOD)
--
-- 于是 @Device@ 不可能被当成 @Buffer@ 传给 FFI（编译期拦住），而解包／构造只能
-- 经 'toPtr' \/ 'fromPtr' 两个窄接口（集中在 FFI 层），构造子**不导出**。
--
-- == 约定
--
-- * 本模块只做类型，不做任何 IO；
-- * 句柄的**生命周期**不由类型系统保证（WebGPU 对象需要显式 release，
--   见后续 @Raw\/Lifecycle.hs@）；这里只保证**类型不混用**。
module Infrastructure.WebGPU.Raw.Types
  ( -- * 对象句柄（构造子不导出）
    Instance
  , Adapter
  , Device
  , Queue
  , Buffer
  , ShaderModule
  , ComputePipeline
  , BindGroup
  , BindGroupLayout
  , PipelineLayout
  , CommandEncoder
  , ComputePassEncoder
    -- * 对象标签（不透明，不可构造）
  , InstanceOD
  , AdapterOD
  , DeviceOD
  , QueueOD
  , BufferOD
  , ShaderModuleOD
  , ComputePipelineOD
  , BindGroupOD
  , BindGroupLayoutOD
  , PipelineLayoutOD
  , CommandEncoderOD
  , ComputePassEncoderOD
    -- * 句柄类
  , Handle(..)
  , Nullable(..)
  ) where

import Data.Kind (Type)
import Foreign.Ptr (Ptr, nullPtr)

-- ---------------------------------------------------------------------------
-- 对象标签（phantom）
-- ---------------------------------------------------------------------------

-- | 每个 WebGPU 对象类型一个标签。**无构造子**，故不存在该类型的值 ——
-- 标签只出现在 'Ptr' 的类型参数位置，纯粹用于让 GHC 区分句柄。
data InstanceOD
data AdapterOD
data DeviceOD
data QueueOD
data BufferOD
data ShaderModuleOD
data ComputePipelineOD
data BindGroupOD
data BindGroupLayoutOD
data PipelineLayoutOD
data CommandEncoderOD
data ComputePassEncoderOD

-- ---------------------------------------------------------------------------
-- 强类型句柄
-- ---------------------------------------------------------------------------

-- | WebGPU 实例句柄（@WGPUInstance@）。
newtype Instance = Instance (Ptr InstanceOD)
  deriving (Eq, Ord, Show)

-- | 适配器句柄（@WGPUAdapter@）—— 由实例选出，代表某个 GPU 后端。
newtype Adapter = Adapter (Ptr AdapterOD)
  deriving (Eq, Ord, Show)

-- | 设备句柄（@WGPUDevice@）—— 所有资源创建的入口。
newtype Device = Device (Ptr DeviceOD)
  deriving (Eq, Ord, Show)

-- | 队列句柄（@WGPUQueue@）—— 由设备派生，提交命令缓冲。
newtype Queue = Queue (Ptr QueueOD)
  deriving (Eq, Ord, Show)

-- | 缓冲句柄（@WGPUBuffer@）。
newtype Buffer = Buffer (Ptr BufferOD)
  deriving (Eq, Ord, Show)

-- | Shader 模块句柄（@WGPUShaderModule@）。
newtype ShaderModule = ShaderModule (Ptr ShaderModuleOD)
  deriving (Eq, Ord, Show)

-- | 计算管线句柄（@WGPUComputePipeline@）。
newtype ComputePipeline = ComputePipeline (Ptr ComputePipelineOD)
  deriving (Eq, Ord, Show)

-- | Bind group 句柄（@WGPUBindGroup@）。
newtype BindGroup = BindGroup (Ptr BindGroupOD)
  deriving (Eq, Ord, Show)

-- | Bind group layout 句柄（@WGPUBindGroupLayout@）。
newtype BindGroupLayout = BindGroupLayout (Ptr BindGroupLayoutOD)
  deriving (Eq, Ord, Show)

-- | 管线布局句柄（@WGPUPipelineLayout@）。
newtype PipelineLayout = PipelineLayout (Ptr PipelineLayoutOD)
  deriving (Eq, Ord, Show)

-- | 命令编码器句柄（@WGPUCommandEncoder@）。
newtype CommandEncoder = CommandEncoder (Ptr CommandEncoderOD)
  deriving (Eq, Ord, Show)

-- | 计算通道编码器句柄（@WGPUComputePassEncoder@）—— 生命周期短，
-- 由 'CommandEncoder' 开启、结束时交出命令缓冲。
newtype ComputePassEncoder = ComputePassEncoder (Ptr ComputePassEncoderOD)
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- 句柄类：解包 / 构造 / 空值
-- ---------------------------------------------------------------------------

-- | 句柄与其对象标签的对应关系。
--
-- 实例都定义在**本模块**（不导出构造子 ⇒ 外部无法伪造句柄，只能经 'fromPtr'
-- 从 FFI 返回值得到）。
class Handle a where
  -- | 该句柄指向的对象标签类型。
  type ObjectOf a :: Type
  -- | 解包成原始指针。**仅供 @Raw\/FFI.hs@ 使用。**
  toPtr :: a -> Ptr (ObjectOf a)
  -- | 由 FFI 返回的原始指针构造句柄。
  fromPtr :: Ptr (ObjectOf a) -> a

-- | 可为 null 的句柄（WebGPU 以空指针表示"创建失败"或"无此对象"）。
class Handle a => Nullable a where
  -- | 空句柄。
  nullHandle :: a
  -- | 是否为空句柄。
  isNullHandle :: a -> Bool

instance Handle Instance where
  type ObjectOf Instance = InstanceOD
  toPtr (Instance p) = p
  fromPtr = Instance

instance Nullable Instance where
  nullHandle = Instance nullPtr
  isNullHandle (Instance p) = p == nullPtr

instance Handle Adapter where
  type ObjectOf Adapter = AdapterOD
  toPtr (Adapter p) = p
  fromPtr = Adapter

instance Nullable Adapter where
  nullHandle = Adapter nullPtr
  isNullHandle (Adapter p) = p == nullPtr

instance Handle Device where
  type ObjectOf Device = DeviceOD
  toPtr (Device p) = p
  fromPtr = Device

instance Nullable Device where
  nullHandle = Device nullPtr
  isNullHandle (Device p) = p == nullPtr

instance Handle Queue where
  type ObjectOf Queue = QueueOD
  toPtr (Queue p) = p
  fromPtr = Queue

instance Nullable Queue where
  nullHandle = Queue nullPtr
  isNullHandle (Queue p) = p == nullPtr

instance Handle Buffer where
  type ObjectOf Buffer = BufferOD
  toPtr (Buffer p) = p
  fromPtr = Buffer

instance Nullable Buffer where
  nullHandle = Buffer nullPtr
  isNullHandle (Buffer p) = p == nullPtr

instance Handle ShaderModule where
  type ObjectOf ShaderModule = ShaderModuleOD
  toPtr (ShaderModule p) = p
  fromPtr = ShaderModule

instance Nullable ShaderModule where
  nullHandle = ShaderModule nullPtr
  isNullHandle (ShaderModule p) = p == nullPtr

instance Handle ComputePipeline where
  type ObjectOf ComputePipeline = ComputePipelineOD
  toPtr (ComputePipeline p) = p
  fromPtr = ComputePipeline

instance Nullable ComputePipeline where
  nullHandle = ComputePipeline nullPtr
  isNullHandle (ComputePipeline p) = p == nullPtr

instance Handle BindGroup where
  type ObjectOf BindGroup = BindGroupOD
  toPtr (BindGroup p) = p
  fromPtr = BindGroup

instance Nullable BindGroup where
  nullHandle = BindGroup nullPtr
  isNullHandle (BindGroup p) = p == nullPtr

instance Handle BindGroupLayout where
  type ObjectOf BindGroupLayout = BindGroupLayoutOD
  toPtr (BindGroupLayout p) = p
  fromPtr = BindGroupLayout

instance Nullable BindGroupLayout where
  nullHandle = BindGroupLayout nullPtr
  isNullHandle (BindGroupLayout p) = p == nullPtr

instance Handle PipelineLayout where
  type ObjectOf PipelineLayout = PipelineLayoutOD
  toPtr (PipelineLayout p) = p
  fromPtr = PipelineLayout

instance Nullable PipelineLayout where
  nullHandle = PipelineLayout nullPtr
  isNullHandle (PipelineLayout p) = p == nullPtr

instance Handle CommandEncoder where
  type ObjectOf CommandEncoder = CommandEncoderOD
  toPtr (CommandEncoder p) = p
  fromPtr = CommandEncoder

instance Nullable CommandEncoder where
  nullHandle = CommandEncoder nullPtr
  isNullHandle (CommandEncoder p) = p == nullPtr

instance Handle ComputePassEncoder where
  type ObjectOf ComputePassEncoder = ComputePassEncoderOD
  toPtr (ComputePassEncoder p) = p
  fromPtr = ComputePassEncoder

instance Nullable ComputePassEncoder where
  nullHandle = ComputePassEncoder nullPtr
  isNullHandle (ComputePassEncoder p) = p == nullPtr
