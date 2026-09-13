{-# LANGUAGE ScopedTypeVariables #-}

-- | hello-compute（W6 阶段二）：真机 GPU 上跑最小 compute，并把结果读回来与 CPU 对拍。
--
-- 算例：输入 [1,2,3,4]（u32），WGSL 逐元素平方，期望 [1,4,9,16]。
--
-- 链路：Instance → Adapter → Device → Queue → CreateBuffer(入/出) → QueueWriteBuffer
--   → CreateShaderModule(WGSL 经 nextInChain) → CreateBindGroupLayout → CreatePipelineLayout
--   → CreateComputePipeline → CreateBindGroup → CreateCommandEncoder → BeginComputePass
--   → SetPipeline/SetBindGroup → DispatchWorkgroups → End → Finish → QueueSubmit
--   → BufferMapAsync → GetMappedRange → 读回 → Unmap → 与 CPU 比对
--
-- 注意：所有描述符先 fillBytes 清零 —— WebGPU 描述符里有我们没填的字段
-- （如 bind group layout entry 的 sampler/texture/storageTexture 内嵌结构），
-- 留垃圾会让校验失败。
module Main (main) where

import Control.Monad (unless)
import Data.Word (Word32)
import Foreign.C.String (withCStringLen)
import Foreign.C.Types (CInt)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (peekArray, pokeArray)
import Foreign.Marshal.Utils (fillBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import Foreign.Storable (poke, sizeOf)

import Infrastructure.WebGPU.Raw.Async (bufferMapSync, requestAdapterSync, requestDeviceSync)
import Infrastructure.WebGPU.Raw.Enums
  ( FeatureLevel (..), PowerPreference (..)
  , bufferUsageCopyDst, bufferUsageCopySrc, bufferUsageMapRead, bufferUsageStorage
  , mapModeRead, mapModeToRaw )
import Infrastructure.WebGPU.Raw.FFI
  ( beginComputePass, bufferGetMappedRange, bufferUnmap, createBindGroup
  , createBindGroupLayout, createBuffer, createCommandEncoder, createComputePipeline
  , copyBufferToBuffer, createInstance, createPipelineLayout, createShaderModule, dispatchWorkgroups
  , endComputePass, finishCommandEncoder, getQueue, queueSubmit, queueWriteBuffer
  , setBindGroup, setPipeline )
import Infrastructure.WebGPU.Raw.Structs
  ( BindGroupDescriptor (..), BindGroupEntry (..), BindGroupLayoutDescriptor (..)
  , BindGroupLayoutEntry (..), BufferBindingLayout (..), BufferDescriptor (..)
  , ChainedStruct (..), ComputePipelineDescriptor (..), ComputeState (..)
  , PipelineLayoutDescriptor (..), RequestAdapterOptions (..)
  , ShaderModuleDescriptor (..), ShaderSourceWGSL (..), StringView (..)
  , bufferBindingTypeStorage, sTypeShaderSourceWGSL, shaderStageCompute )
import Infrastructure.WebGPU.Raw.Types (toPtr)

inputData :: [Word32]
inputData = [1, 2, 3, 4]

expected :: [Word32]
expected = map (\x -> x * x) inputData

dataBytes :: Int
dataBytes = length inputData * 4

wgslSource :: String
wgslSource = unlines
  [ "@group(0) @binding(0) var<storage, read_write> inp: array<u32>;"
  , "@group(0) @binding(1) var<storage, read_write> outp: array<u32>;"
  , ""
  , "@compute @workgroup_size(4)"
  , "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {"
  , "  let i = gid.x;"
  , "  outp[i] = inp[i] * inp[i];"
  , "}"
  ]

noLabel :: StringView
noLabel = StringView nullPtr 0

withCleared :: (Ptr a -> IO b) -> IO b
withCleared f = allocaBytes 256 $ \p -> fillBytes p 0 256 >> f p

main :: IO ()
main = do
  putStrLn "=== WebGPU hello-compute（u32 逐元素平方）==="
  putStrLn ("输入: " ++ show inputData)
  putStrLn ("期望: " ++ show expected)

  inst <- createInstance

  adapterE <- withCleared $ \optsPtr -> do
    poke optsPtr RequestAdapterOptions
      { raoNextInChain = nullPtr
      , raoFeatureLevel = FeatureLevelCore
      , raoPowerPreference = PowerPreferenceHighPerformance
      , raoForceFallbackAdapter = 0
      , raoBackendType = 0
      , raoCompatibleSurface = nullPtr }
    requestAdapterSync inst optsPtr
  adapter <- either (failWith "requestAdapter") pure adapterE

  deviceE <- requestDeviceSync inst adapter nullPtr
  device <- either (failWith "requestDevice") pure deviceE
  queue <- getQueue device

  inBuf <- withCleared $ \p -> do
    poke p BufferDescriptor
      { bdNextInChain = nullPtr, bdLabel = noLabel
      , bdUsage = bufferUsageCopyDst <> bufferUsageStorage
      , bdSize = fromIntegral dataBytes, bdMappedAtCreation = 0 }
    createBuffer device p

  outBuf <- withCleared $ \p -> do
    poke p BufferDescriptor
      { bdNextInChain = nullPtr, bdLabel = noLabel
      -- WebGPU 规定 MAP_READ 必须与相反的 COPY 搭配（MAP_READ ↔ COPY_DST）
      , bdUsage = bufferUsageStorage <> bufferUsageCopySrc
      , bdSize = fromIntegral dataBytes, bdMappedAtCreation = 0 }
    createBuffer device p

  -- 读回专用 buffer：MAP_READ 只能与 COPY_DST 搭配（不能叠 STORAGE），
  -- 故走「outBuf(Storage|CopySrc) --CopyBufferToBuffer--> readBack(MapRead|CopyDst)」。
  readBack <- withCleared $ \p -> do
    poke p BufferDescriptor
      { bdNextInChain = nullPtr, bdLabel = noLabel
      , bdUsage = bufferUsageMapRead <> bufferUsageCopyDst
      , bdSize = fromIntegral dataBytes, bdMappedAtCreation = 0 }
    createBuffer device p

  withCleared $ \(dataPtr :: Ptr Word32) -> do
    pokeArray dataPtr inputData
    queueWriteBuffer (toPtr queue) (toPtr inBuf) 0 (castPtr dataPtr) (fromIntegral dataBytes)

  withCStringLen wgslSource $ \(codePtr, codeLen) ->
    withCleared $ \(wgslPtr :: Ptr ShaderSourceWGSL) ->
    withCleared $ \(smPtr :: Ptr ShaderModuleDescriptor) -> do
      poke wgslPtr ShaderSourceWGSL
        { sswChain = ChainedStruct nullPtr sTypeShaderSourceWGSL
        , sswCode = StringView (castPtr codePtr) (fromIntegral codeLen) }
      poke smPtr (ShaderModuleDescriptor { smdNextInChain = castPtr wgslPtr, smdLabel = noLabel })
      shader <- createShaderModule device smPtr

      withCleared $ \(entriesPtr :: Ptr BindGroupLayoutEntry) -> do
        let stride = sizeOf (undefined :: BindGroupLayoutEntry)
            mkEntry b = BindGroupLayoutEntry
              { bgleNextInChain = nullPtr
              , bgleBinding = b
              , bgleVisibility = shaderStageCompute
              , bgleBindingArraySize = 0
              , bgleBuffer = BufferBindingLayout
                  { bblNextInChain = nullPtr
                  , bblType = bufferBindingTypeStorage
                  , bblHasDynamicOffset = 0
                  , bblMinBindingSize = 0 } }
        poke entriesPtr (mkEntry 0)
        poke (entriesPtr `plusPtr` stride) (mkEntry 1)

        withCleared $ \(bglPtr :: Ptr BindGroupLayoutDescriptor) -> do
          poke bglPtr BindGroupLayoutDescriptor
            { bgldNextInChain = nullPtr, bgldLabel = noLabel
            , bgldEntryCount = 2, bgldEntries = entriesPtr }
          bgl <- createBindGroupLayout device bglPtr

          withCleared $ \(layoutsPtr :: Ptr (Ptr ())) ->
            withCleared $ \(plPtr :: Ptr PipelineLayoutDescriptor) -> do
              poke layoutsPtr (castPtr (toPtr bgl))
              poke plPtr PipelineLayoutDescriptor
                { pldNextInChain = nullPtr, pldLabel = noLabel
                , pldBindGroupLayoutCount = 1
                , pldBindGroupLayouts = castPtr layoutsPtr
                , pldImmediateSize = 0 }
              pl <- createPipelineLayout device plPtr

              withCStringLen "main" $ \(entryPtr, entryLen) ->
                withCleared $ \(cpPtr :: Ptr ComputePipelineDescriptor) -> do
                  poke cpPtr ComputePipelineDescriptor
                    { cpdNextInChain = nullPtr, cpdLabel = noLabel
                    , cpdLayout = castPtr (toPtr pl)
                    , cpdCompute = ComputeState
                        { cstNextInChain = nullPtr
                        , cstModule = castPtr (toPtr shader)
                        , cstEntryPoint = StringView (castPtr entryPtr) (fromIntegral entryLen)
                        , cstConstantCount = 0
                        , cstConstants = nullPtr } }
                  pipeline <- createComputePipeline device cpPtr

                  withCleared $ \(bgEntriesPtr :: Ptr BindGroupEntry) -> do
                    let bStride = sizeOf (undefined :: BindGroupEntry)
                        mkBge b buf = BindGroupEntry
                          { bgeNextInChain = nullPtr
                          , bgeBinding = b
                          , bgeBuffer = castPtr (toPtr buf)
                          , bgeOffset = 0
                          , bgeSize = fromIntegral dataBytes
                          , bgeSampler = nullPtr
                          , bgeTextureView = nullPtr }
                    poke bgEntriesPtr (mkBge 0 inBuf)
                    poke (bgEntriesPtr `plusPtr` bStride) (mkBge 1 outBuf)

                    withCleared $ \(bgPtr :: Ptr BindGroupDescriptor) -> do
                      poke bgPtr BindGroupDescriptor
                        { bgdNextInChain = nullPtr, bgdLabel = noLabel
                        , bgdLayout = castPtr (toPtr bgl)
                        , bgdEntryCount = 2, bgdEntries = bgEntriesPtr }
                      bindGroup <- createBindGroup device bgPtr

                      enc <- createCommandEncoder device
                      pass <- beginComputePass enc
                      setPipeline (toPtr pass) (toPtr pipeline)
                      setBindGroup (toPtr pass) 0 (toPtr bindGroup) 0 nullPtr
                      dispatchWorkgroups (toPtr pass) 1 1 1
                      endComputePass (toPtr pass)
                      -- 把结果从 outBuf 搬进可映射的 readBack
                      copyBufferToBuffer (toPtr enc) (toPtr outBuf) 0 (toPtr readBack) 0
                                         (fromIntegral dataBytes)
                      cmdBuf <- finishCommandEncoder (toPtr enc) nullPtr
                      withCleared $ \(cmdBufsPtr :: Ptr (Ptr ())) -> do
                        poke cmdBufsPtr cmdBuf
                        queueSubmit (toPtr queue) 1 cmdBufsPtr

                        mapE <- bufferMapSync inst readBack (mapModeToRaw mapModeRead) 0
                                               (fromIntegral dataBytes)
                        case mapE of
                          Left st -> failWith "bufferMap" st
                          Right () -> do
                            mapped <- bufferGetMappedRange (toPtr readBack) 0 (fromIntegral dataBytes)
                            got <- peekArray (length inputData) (castPtr mapped :: Ptr Word32)
                            bufferUnmap (toPtr readBack)
                            putStrLn ("实际: " ++ show got)
                            if got == expected
                              then putStrLn "\n✓ GPU 结果与 CPU 参考答案逐元素一致 —— hello-compute 通过"
                              else do
                                putStrLn "\n✗ 结果不一致"
                                unless (got == expected) (pure ())
  where
    failWith :: String -> CInt -> IO a
    failWith what st = do
      putStrLn ("✗ " ++ what ++ " 失败，status=" ++ show st)
      fail ("WebGPU " ++ what ++ " failed")
