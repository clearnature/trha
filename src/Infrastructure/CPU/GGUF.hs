{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | GGUF container reader (format v3).
--
-- Field order and widths follow llama.cpp's @ggml/src/gguf.cpp@ (verified
-- against the reference source, not from memory):
--
-- > magic "GGUF" (4) | version u32 | n_tensors i64 | n_kv i64
-- > n_kv × ( key: string , type: u32 , value )
-- > n_tensors × ( name: string , n_dims u32 , dims × u64 , type u32 , offset u64 )
-- > pad to general.alignment (default 32, must be a power of two) → tensor data
--
-- Strings are @u64 length + bytes@ (no NUL); integers are little-endian.
-- Tensor dims are fastest-varying first, i.e. ggml's @ne[0]@ is the first
-- entry — so a (rows, cols) matrix reads back as @[cols, rows]@.
--
-- Value widths matter: UINT8/INT8 are one byte and UINT16/INT16 are two, while
-- the reference stores 4/8/16-bit values in their own widths (see
-- @gguf_read_*@).  Reading them all as u32 desynchronises the whole file.
module Infrastructure.CPU.GGUF
  ( GGUF(..)
  , GGUFTensor(..)
  , GGUFValue(..)
  , loadGGUF
  , ggufMetaText
  , ggufMetaU32
  , tensorElemCount
  , ggufTensorBytes
  ) where

import qualified Data.ByteString as BS
import Data.Bits ((.&.))
import Data.Int (Int8, Int16, Int32, Int64)
import qualified Data.Map as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word8, Word16, Word32, Word64)
import GHC.Float (castWord32ToFloat, castWord64ToDouble)

-- | One metadata value (GGUF's type lattice, gguf.h:54-67).
data GGUFValue
  = VUInt   Word64
  | VInt    Int64
  | VFloat  Double
  | VBool   Bool
  | VString Text
  | VArray  Word32 GGUFValue [GGUFValue]   -- ^ element type id, a sample, elements
  deriving (Show, Eq)

-- | One tensor's directory entry; its bytes stay in the file image.
data GGUFTensor = GGUFTensor
  { gtName   :: Text
  , gtDims   :: [Word64]    -- ^ fastest-varying first (ggml @ne[0]@ first)
  , gtType   :: Word32      -- ^ ggml type id: 0=F32, 1=F16, 2=Q4_0, 8=Q8_0 …
  , gtOffset :: Word64      -- ^ from the start of the tensor-data section
  } deriving (Show, Eq)

data GGUF = GGUF
  { ggVersion   :: Word32
  , ggAlignment :: Word64
  , ggMeta      :: Map.Map Text GGUFValue
  , ggTensors   :: [GGUFTensor]
  , ggDataStart :: Int            -- ^ byte offset of the tensor-data section
  , ggImage     :: BS.ByteString  -- ^ whole file; tensors are indexed into it
  } deriving (Show, Eq)

--------------------------------------------------------------------------------
-- A little-endian cursor over the file image
--------------------------------------------------------------------------------

data Cur = Cur { cBuf :: BS.ByteString, cPos :: Int }

leN :: Int -> BS.ByteString -> Int -> Word64
leN n b p = foldr (\i acc -> acc * 256 + fromIntegral (BS.index b (p + i))) 0 [0 .. n - 1]

u8 :: Cur -> Either Text (Word8, Cur)
u8 (Cur b p)
  | p + 1 > BS.length b = Left "GGUF: truncated u8"
  | otherwise           = Right (BS.index b p, Cur b (p + 1))

u16 :: Cur -> Either Text (Word16, Cur)
u16 (Cur b p)
  | p + 2 > BS.length b = Left "GGUF: truncated u16"
  | otherwise           = Right (fromIntegral (leN 2 b p), Cur b (p + 2))

u32 :: Cur -> Either Text (Word32, Cur)
u32 (Cur b p)
  | p + 4 > BS.length b = Left "GGUF: truncated u32"
  | otherwise           = Right (fromIntegral (leN 4 b p), Cur b (p + 4))

u64 :: Cur -> Either Text (Word64, Cur)
u64 (Cur b p)
  | p + 8 > BS.length b = Left "GGUF: truncated u64"
  | otherwise           = Right (leN 8 b p, Cur b (p + 8))

i64 :: Cur -> Either Text (Int64, Cur)
i64 c = do
  (w, c') <- u64 c
  pure (fromIntegral w, c')

-- | A GGUF string: u64 length, then that many UTF-8 bytes (no NUL).
gstr :: Cur -> Either Text (Text, Cur)
gstr (Cur b p)
  | p + 8 > BS.length b = Left "GGUF: truncated string length"
  | otherwise =
      let n = fromIntegral (leN 8 b p) :: Int
      in if p + 8 + n > BS.length b
           then Left "GGUF: truncated string body"
           else Right ( TE.decodeUtf8With lenientDecode (BS.take n (BS.drop (p + 8) b))
                      , Cur b (p + 8 + n) )

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

-- | Parse a GGUF file's header, metadata and tensor directory.  The tensor
-- payload stays in the image: slice it with @ggufTensorBytes@.
loadGGUF :: FilePath -> IO (Either Text GGUF)
loadGGUF path = do
  img <- BS.readFile path
  pure $ run img
  where
    run img
      | BS.length img < 24      = Left "GGUF: file too small for a header"
      | BS.take 4 img /= "GGUF" = Left "GGUF: bad magic"
      | otherwise               = do
          (version, c1)  <- u32 (Cur img 4)
          if version < 2 || version > 3
            then Left ("GGUF: unsupported version " <> T.pack (show version))
            else do
              (nTensors, c2) <- i64 c1
              (nKv, c3)      <- i64 c2
              if nTensors < 0 || nKv < 0
                then Left "GGUF: negative tensor/kv counts"
                else do
                  (kv, c4)  <- readKV (fromIntegral nKv) c3 []
                  (tis, c5) <- readTensors (fromIntegral nTensors) c4 []
                  let meta  = Map.fromList kv
                      align = case Map.lookup "general.alignment" meta of
                                Just (VUInt a) -> a
                                _              -> 32
                  if align == 0 || (align .&. (align - 1)) /= 0
                    then Left ("GGUF: alignment " <> T.pack (show align) <> " is not a power of two")
                    else do
                      let pos   = cPos c5
                          padTo = fromIntegral align :: Int
                          padded = ((pos + padTo - 1) `div` padTo) * padTo
                      pure GGUF
                        { ggVersion   = version
                        , ggAlignment = align
                        , ggMeta      = meta
                        , ggTensors   = tis
                        , ggDataStart = padded
                        , ggImage     = img
                        }

    readKV :: Int -> Cur -> [(Text, GGUFValue)] -> Either Text ([(Text, GGUFValue)], Cur)
    readKV 0 c acc = Right (reverse acc, c)
    readKV n c acc = do
      (key, c1)  <- gstr c
      (ty, c2)   <- u32 c1
      (val, c3)  <- readValue ty c2
      readKV (n - 1) c3 ((key, val) : acc)

    -- Widths follow gguf.cpp's readers exactly: 0/1 are one byte, 2/3 two.
    readValue :: Word32 -> Cur -> Either Text (GGUFValue, Cur)
    readValue 0  c = fmap (\(w, c') -> (VUInt (fromIntegral w), c')) (u8 c)
    readValue 1  c = fmap (\(w, c') -> (VInt (fromIntegral (fromIntegral w :: Int8)), c')) (u8 c)
    readValue 2  c = fmap (\(w, c') -> (VUInt (fromIntegral w), c')) (u16 c)
    readValue 3  c = fmap (\(w, c') -> (VInt (fromIntegral (fromIntegral w :: Int16)), c')) (u16 c)
    readValue 4  c = fmap (\(w, c') -> (VUInt (fromIntegral w), c')) (u32 c)
    readValue 5  c = fmap (\(w, c') -> (VInt (fromIntegral (fromIntegral w :: Int32)), c')) (u32 c)
    readValue 6  c = fmap (\(w, c') -> (VFloat (realToFrac (castWord32ToFloat w)), c')) (u32 c)
    readValue 7  c = fmap (\(w, c') -> (VBool (w /= 0), c')) (u8 c)
    readValue 8  c = fmap (\(s, c') -> (VString s, c')) (gstr c)
    readValue 9  c = do
      (et, c1)  <- u32 c
      (cnt, c2) <- u64 c1
      (xs, c3)  <- readElems et (fromIntegral cnt) c2 []
      pure (VArray et (firstOr (VUInt 0) xs) xs, c3)
    readValue 10 c = fmap (\(w, c') -> (VUInt w, c')) (u64 c)
    readValue 11 c = fmap (\(w, c') -> (VInt w, c')) (i64 c)
    readValue 12 c = fmap (\(w, c') -> (VFloat (castWord64ToDouble w), c')) (u64 c)
    readValue t  _ = Left ("GGUF: unknown metadata type " <> T.pack (show t))

    readElems :: Word32 -> Int -> Cur -> [GGUFValue] -> Either Text ([GGUFValue], Cur)
    readElems _  0 c acc = Right (reverse acc, c)
    readElems et n c acc = do
      (v, c') <- readValue et c
      readElems et (n - 1) c' (v : acc)

    readTensors :: Int -> Cur -> [GGUFTensor] -> Either Text ([GGUFTensor], Cur)
    readTensors 0 c acc = Right (reverse acc, c)
    readTensors n c acc = do
      (name, c1) <- gstr c
      (nd, c2)   <- u32 c1
      (dims, c3) <- readDims (fromIntegral nd) c2 []
      (ty, c4)   <- u32 c3
      (off, c5)  <- u64 c4
      readTensors (n - 1) c5 (GGUFTensor name dims ty off : acc)

    readDims :: Int -> Cur -> [Word64] -> Either Text ([Word64], Cur)
    readDims 0 c acc = Right (reverse acc, c)
    readDims n c acc = do
      (d, c') <- u64 c
      readDims (n - 1) c' (d : acc)

    firstOr d []    = d
    firstOr _ (x:_) = x

-- | A metadata string, when present.
ggufMetaText :: GGUF -> Text -> Maybe Text
ggufMetaText g k = case Map.lookup k (ggMeta g) of
  Just (VString s) -> Just s
  _                -> Nothing

-- | A metadata integer, when present.
ggufMetaU32 :: GGUF -> Text -> Maybe Word32
ggufMetaU32 g k = case Map.lookup k (ggMeta g) of
  Just (VUInt w) -> Just (fromIntegral w)
  _              -> Nothing

-- | How many elements a tensor holds.
tensorElemCount :: GGUFTensor -> Int
tensorElemCount = product . map fromIntegral . gtDims

-- | The tensor's raw bytes, sliced out of the file image.
ggufTensorBytes :: GGUF -> Int -> GGUFTensor -> BS.ByteString
ggufTensorBytes g size t =
  BS.take size (BS.drop (ggDataStart g + fromIntegral (gtOffset t)) (ggImage g))
