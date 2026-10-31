{-# LANGUAGE ScopedTypeVariables #-}

-- | 计算内核：WGSL → ShaderModule → BindGroupLayout → PipelineLayout → Pipeline，
-- 并负责编码一次 dispatch（可顺带把结果搬进读回缓冲）。
--
-- 用法（见 @benchmarks\/webgpu\/Compute.hs@）：
--
-- > k <- newKernel ctx wgslSrc 2 "main"        -- 两个 storage buffer 绑定
-- > out <- runKernel ctx k [inBuf, outBuf] (1,1,1) (Just (rb, 4))
module Infrastructure.WebGPU.Kernel
  ( Kernel (..)
  , newKernel
  , runKernel
  ) where

import Data.Word (Word32)
import Foreign.C.String (withCStringLen)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Utils (fillBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import Foreign.Storable (poke, sizeOf)

import Infrastructure.WebGPU.Buffer (GpuBuffer (..), readWords)
import Infrastructure.WebGPU.Context (Context (..))
import Infrastructure.WebGPU.Error (clearError, lastError)
import Infrastructure.WebGPU.Raw.FFI
  ( beginComputePass
  , copyBufferToBuffer
  , createBindGroup
  , createBindGroupLayout
  , createCommandEncoder
  , createComputePipeline
  , createPipelineLayout
  , createShaderModule
  , dispatchWorkgroups
  , endComputePass
  , finishCommandEncoder
  , queueSubmit
  , setBindGroup
  , setPipeline
  )
import Infrastructure.WebGPU.Raw.Structs
  ( BindGroupDescriptor (..)
  , BindGroupEntry (..)
  , BindGroupLayoutDescriptor (..)
  , BindGroupLayoutEntry (..)
  , BufferBindingLayout (..)
  , ChainedStruct (..)
  , ComputePipelineDescriptor (..)
  , ComputeState (..)
  , PipelineLayoutDescriptor (..)
  , ShaderModuleDescriptor (..)
  , ShaderSourceWGSL (..)
  , StringView (..)
  , bufferBindingTypeStorage
  , sTypeShaderSourceWGSL
  , shaderStageCompute
  )
import Infrastructure.WebGPU.Raw.Types (BindGroup, BindGroupLayout, ComputePipeline, toPtr)

-- | 已编译的计算内核。
data Kernel = Kernel
  { kPipeline :: ComputePipeline
  , kLayout :: BindGroupLayout
  , kBindings :: Int
  }

noLabel :: StringView
noLabel = StringView nullPtr 0

withCleared :: (Ptr a -> IO b) -> IO b
withCleared f = allocaBytes 256 $ \p -> fillBytes p 0 256 >> f p

-- | 指定字节数的清零分配。
--
-- 条目**数组**必须按个数算尺寸：@BindGroupLayoutEntry@ 约 128 字节，固定 256 只能装
-- 两个；装 3 个就会越界写，后续字段读到垃圾（实测报
-- "invalid sampler binding type for sampler binding layout at binding 2"）。
withClearedN :: Int -> (Ptr a -> IO b) -> IO b
withClearedN sz f = allocaBytes sz $ \p -> fillBytes p 0 sz >> f p

-- | 由 WGSL 源码建内核；@nBindings@ 是 storage buffer 绑定个数（binding 0..n-1）。
newKernel :: Context -> String -> Int -> String -> IO Kernel
newKernel ctx wgsl nBindings entry = do
  clearError
  shader <- withCStringLen wgsl $ \(codePtr, codeLen) ->
    withCleared $ \(wgslPtr :: Ptr ShaderSourceWGSL) ->
      withCleared $ \(smPtr :: Ptr ShaderModuleDescriptor) -> do
        poke
          wgslPtr
          ShaderSourceWGSL
            { sswChain = ChainedStruct nullPtr sTypeShaderSourceWGSL
            , sswCode = StringView (castPtr codePtr) (fromIntegral codeLen)
            }
        poke smPtr (ShaderModuleDescriptor { smdNextInChain = castPtr wgslPtr, smdLabel = noLabel })
        createShaderModule (ctxDevice ctx) smPtr

  let bglStride = sizeOf (undefined :: BindGroupLayoutEntry)
  bgl <- withClearedN (bglStride * nBindings + 64) $ \(entriesPtr :: Ptr BindGroupLayoutEntry) -> do
    let stride = bglStride
        mkEntry i = BindGroupLayoutEntry
          { bgleNextInChain = nullPtr
          , bgleBinding = fromIntegral i
          , bgleVisibility = shaderStageCompute
          , bgleBindingArraySize = 0
          , bgleBuffer = BufferBindingLayout
              { bblNextInChain = nullPtr
              , bblType = bufferBindingTypeStorage
              , bblHasDynamicOffset = 0
              , bblMinBindingSize = 0 }
          }
    mapM_ (\i -> poke (entriesPtr `plusPtr` (i * stride)) (mkEntry i)) [0 .. nBindings - 1]
    withCleared $ \(bglPtr :: Ptr BindGroupLayoutDescriptor) -> do
      poke
        bglPtr
        BindGroupLayoutDescriptor
          { bgldNextInChain = nullPtr
          , bgldLabel = noLabel
          , bgldEntryCount = fromIntegral nBindings
          , bgldEntries = entriesPtr
          }
      createBindGroupLayout (ctxDevice ctx) bglPtr

  pl <- withCleared $ \(layoutsPtr :: Ptr (Ptr ())) ->
    withCleared $ \(plPtr :: Ptr PipelineLayoutDescriptor) -> do
      poke layoutsPtr (castPtr (toPtr bgl))
      poke
        plPtr
        PipelineLayoutDescriptor
          { pldNextInChain = nullPtr
          , pldLabel = noLabel
          , pldBindGroupLayoutCount = 1
          , pldBindGroupLayouts = castPtr layoutsPtr
          , pldImmediateSize = 0
          }
      createPipelineLayout (ctxDevice ctx) plPtr

  pipeline <- withCStringLen entry $ \(entryPtr, entryLen) ->
    withCleared $ \(cpPtr :: Ptr ComputePipelineDescriptor) -> do
      poke
        cpPtr
        ComputePipelineDescriptor
          { cpdNextInChain = nullPtr
          , cpdLabel = noLabel
          , cpdLayout = castPtr (toPtr pl)
          , cpdCompute = ComputeState
              { cstNextInChain = nullPtr
              , cstModule = castPtr (toPtr shader)
              , cstEntryPoint = StringView (castPtr entryPtr) (fromIntegral entryLen)
              , cstConstantCount = 0
              , cstConstants = nullPtr }
          }
      createComputePipeline (ctxDevice ctx) cpPtr

  e <- lastError
  case e of
    Just err -> error ("wgpu newKernel failed: " <> show err)
    Nothing -> pure ()
  pure (Kernel pipeline bgl nBindings)

-- | 跑一次内核：@buffers@ 按 binding 顺序（0..n-1）给出；@workgroups@ 是 (x,y,z)。
-- 若给 @Just (readBack, n)@，则在提交前把第 0 个 buffer 的内容拷进 @readBack@（n 个 u32），
-- 并返回读回结果；否则返回 @[]@。
runKernel
  :: Context
  -> Kernel
  -> [GpuBuffer]
  -> (Word32, Word32, Word32)
  -> Maybe (GpuBuffer, GpuBuffer, Int)
  -- ^ @(拷贝源, 读回目标, 元素个数)@；@Nothing@ 表示不读回
  -> IO [Word32]
runKernel ctx k buffers (wx, wy, wz) readBack = do
  let bgStride = sizeOf (undefined :: BindGroupEntry)
  bindGroup <- withClearedN (bgStride * length buffers + 64) $ \(bgEntriesPtr :: Ptr BindGroupEntry) -> do
    let stride = bgStride
        mkBge i gb = BindGroupEntry
          { bgeNextInChain = nullPtr
          , bgeBinding = fromIntegral i
          , bgeBuffer = castPtr (toPtr (gbHandle gb))
          , bgeOffset = 0
          , bgeSize = fromIntegral (gbBytes gb)
          , bgeSampler = nullPtr
          , bgeTextureView = nullPtr
          }
    mapM_ (\(i, gb) -> poke (bgEntriesPtr `plusPtr` (i * stride)) (mkBge i gb)) (zip [0 :: Int ..] buffers)
    withCleared $ \(bgPtr :: Ptr BindGroupDescriptor) -> do
      poke
        bgPtr
        BindGroupDescriptor
          { bgdNextInChain = nullPtr
          , bgdLabel = noLabel
          , bgdLayout = castPtr (toPtr (kLayout k))
          , bgdEntryCount = fromIntegral (kBindings k)
          , bgdEntries = bgEntriesPtr
          }
      createBindGroup (ctxDevice ctx) bgPtr

  enc <- createCommandEncoder (ctxDevice ctx)
  pass <- beginComputePass enc
  setPipeline (toPtr pass) (toPtr (kPipeline k))
  setBindGroup (toPtr pass) 0 (toPtr bindGroup) 0 nullPtr
  dispatchWorkgroups (toPtr pass) wx wy wz
  endComputePass (toPtr pass)

  case readBack of
    Just (src, rb, n) ->
      copyBufferToBuffer
        (toPtr enc)
        (toPtr (gbHandle src))
        0
        (toPtr (gbHandle rb))
        0
        (fromIntegral (n * 4))
    _ -> pure ()

  cmdBuf <- finishCommandEncoder (toPtr enc) nullPtr
  withCleared $ \(cmdBufsPtr :: Ptr (Ptr ())) -> do
    poke cmdBufsPtr cmdBuf
    queueSubmit (toPtr (ctxQueue ctx)) 1 cmdBufsPtr

  case readBack of
    Just (_, rb, n) -> readWords ctx rb n
    Nothing -> pure []
