{-# LANGUAGE ScopedTypeVariables #-}

-- | GPU 缓冲：创建、上传、读回。
--
-- 读回的关键约束（WebGPU 校验规则，实测踩过）：@MAP_READ@ 只能与 @COPY_DST@ 搭配，
-- **不能**叠加 @STORAGE@。于是"shader 可写"与"CPU 可读"必须分成两个 buffer：
--
-- > storageBuffer (Storage|CopySrc)  --CopyBufferToBuffer-->  readBackBuffer (MapRead|CopyDst)
module Infrastructure.WebGPU.Buffer
  ( GpuBuffer (..)
  , newStorageBuffer
  , newReadBackBuffer
  , uploadWords
  , readWords
  ) where

import Data.Word (Word32)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (peekArray, pokeArray)
import Foreign.Marshal.Utils (fillBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (poke)

import Infrastructure.WebGPU.Context (Context (..))
import Infrastructure.WebGPU.Raw.Async (bufferMapSync)
import Infrastructure.WebGPU.Raw.Enums
  ( BufferUsage
  , bufferUsageCopyDst
  , bufferUsageCopySrc
  , bufferUsageMapRead
  , bufferUsageStorage
  , mapModeRead
  , mapModeToRaw
  )
import Infrastructure.WebGPU.Raw.FFI
  ( bufferGetMappedRange
  , bufferUnmap
  , createBuffer
  , queueWriteBuffer
  )
import Infrastructure.WebGPU.Raw.Structs (BufferDescriptor (..), StringView (..))
import Infrastructure.WebGPU.Raw.Types (Buffer, toPtr)

-- | 一个 GPU 缓冲及其字节数。
data GpuBuffer = GpuBuffer
  { gbHandle :: Buffer
  , gbBytes :: Int
  }

-- | 供 shader 读写、并可被拷贝出去的存储缓冲（@Storage | CopySrc | CopyDst@）。
newStorageBuffer :: Context -> Int -> IO GpuBuffer
newStorageBuffer ctx n = do
  buf <- mkBuffer ctx (bufferUsageStorage <> bufferUsageCopySrc <> bufferUsageCopyDst) n
  pure (GpuBuffer buf n)

-- | 供 CPU 映射读回的缓冲（@MapRead | CopyDst@ —— 不能带 Storage）。
newReadBackBuffer :: Context -> Int -> IO GpuBuffer
newReadBackBuffer ctx n = do
  buf <- mkBuffer ctx (bufferUsageMapRead <> bufferUsageCopyDst) n
  pure (GpuBuffer buf n)

mkBuffer :: Context -> BufferUsage -> Int -> IO Buffer
mkBuffer ctx usage n = allocaBytes 256 $ \p -> do
  fillBytes p 0 256
  poke
    p
    BufferDescriptor
      { bdNextInChain = nullPtr
      , bdLabel = StringView nullPtr 0
      , bdUsage = usage
      , bdSize = fromIntegral n
      , bdMappedAtCreation = 0
      }
  createBuffer (ctxDevice ctx) p

-- | 把一批 u32 写进缓冲（@QueueWriteBuffer@）。
uploadWords :: Context -> GpuBuffer -> [Word32] -> IO ()
uploadWords ctx gb ws =
  allocaBytes (max 4 (length ws * 4)) $ \(p :: Ptr Word32) -> do
    fillBytes p 0 (max 4 (length ws * 4))
    pokeArray p ws
    queueWriteBuffer
      (toPtr (ctxQueue ctx))
      (toPtr (gbHandle gb))
      0
      (castPtr p)
      (fromIntegral (length ws * 4))

-- | 映射读回 n 个 u32（@BufferMapAsync@ → @GetMappedRange@ → @Unmap@）。
readWords :: Context -> GpuBuffer -> Int -> IO [Word32]
readWords ctx gb n = do
  r <- bufferMapSync (ctxInstance ctx) (gbHandle gb) (mapModeToRaw mapModeRead) 0 (fromIntegral (n * 4))
  case r of
    Left st -> fail ("bufferMap 失败, status=" ++ show st)
    Right () -> do
      mapped <- bufferGetMappedRange (toPtr (gbHandle gb)) 0 (fromIntegral (n * 4))
      ws <- peekArray n (castPtr mapped :: Ptr Word32)
      bufferUnmap (toPtr (gbHandle gb))
      pure ws
