{-# LANGUAGE OverloadedStrings #-}

-- | SOV3 checkpoint reader — pyBitNet's ternary weight container.
--
-- Layout and packing were taken from the producer/consumer pair in
-- @bitnet/training/sov_checkpoint.py@ (save at :889-908, load at :847-866),
-- verified against a real file (byte accounting closes exactly):
--
-- > ['SOV3'(4)] [version u32] [meta_len u32] [meta JSON] [packed tensors …]
--
-- Each tensor is 5 trits per byte, base-3 with the most significant digit
-- first: @trit_i = (byte \`div\` 3^(4-i)) \`mod\` 3@, values in {0,1,2} — the
-- reference feeds them straight into a float tensor, so there is no scale.
-- Tensors sit tightly packed in @meta.tensors@ order; the writer leaves each
-- entry's @offset@ at 0, so offsets are recomputed here by accumulation.
module Infrastructure.CPU.SOV3
  ( SOV3(..)
  , SOV3Tensor(..)
  , loadSOV3
  , sov3Tensor
  , sov3TensorFloats
  , unpackTrits
  , unpackTritsInt
    -- torch.save 的 ZIP 容器（训练后的 checkpoint 用它，不是裸 SOV3）
  , TZEntry(..)
  , loadTorchZip
  , tzEntry
  , tzNames
  , indexZip
  , sovSlice
  , sovLookup
  ) where

import Data.Aeson (Value(..), decode)
import Data.Char (isAlphaNum, isSpace)
import Data.List (isSuffixOf)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Vector as V
import Data.Word (Word32)

-- | One tensor's directory entry.
data SOV3Tensor = SOV3Tensor
  { stName  :: Text
  , stShape :: [Int]
  , stSize  :: Int    -- ^ packed byte length
  , stStart :: Int    -- ^ recomputed byte offset inside the image
  } deriving (Show, Eq)

data SOV3 = SOV3
  { svVersion   :: Word32
  , svMeta      :: Value          -- ^ the whole header JSON (source, chern, …)
  , svTensors   :: [SOV3Tensor]
  , svDataStart :: Int
  , svImage     :: BS.ByteString
  } deriving (Show, Eq)

le32 :: BS.ByteString -> Int -> Word32
le32 b p = fromIntegral (BS.index b p)
         + 256 * fromIntegral (BS.index b (p + 1))
         + 65536 * fromIntegral (BS.index b (p + 2))
         + 16777216 * fromIntegral (BS.index b (p + 3))

-- | Read a SOV3 checkpoint's header and tensor directory.
loadSOV3 :: FilePath -> IO (Either Text SOV3)
loadSOV3 path = do
  img <- BS.readFile path
  pure $ parse img
  where
    parse img
      | BS.length img < 12      = Left "SOV3: file too small for a header"
      | BS.take 4 img /= "SOV3" = Left "SOV3: bad magic"
      | otherwise =
          let metaLen   = fromIntegral (le32 img 8) :: Int
              metaStart = 12
          in if metaStart + metaLen > BS.length img
               then Left "SOV3: meta JSON runs past EOF"
               else case decode (BL.fromStrict (BS.take metaLen (BS.drop metaStart img))) of
                 Nothing   -> Left "SOV3: meta JSON is not valid JSON"
                 Just meta ->
                   let start   = metaStart + metaLen
                       entries = case meta of
                                   Object o -> case KM.lookup "tensors" o of
                                     Just (Object ts) -> KM.toList ts
                                     _                -> []
                                   _ -> []
                   in Right SOV3
                        { svVersion   = le32 img 4
                        , svMeta      = meta
                        , svTensors   = direct entries start
                        , svDataStart = start
                        , svImage     = img
                        }

-- | Turn directory entries into tensors with recomputed offsets.
direct :: [(Key.Key, Value)] -> Int -> [SOV3Tensor]
direct = go
  where
    go [] _ = []
    go ((k, v) : rest) off =
      let shape = case v of
            Object o -> case KM.lookup "shape" o of
              Just (Array a) -> [ round d | Number n <- V.toList a, let d = realToFrac n :: Double ]
              _              -> []
            _ -> []
          size = case v of
            Object o -> case KM.lookup "size" o of
              Just (Number n) -> round n
              _               -> 0
            _ -> 0
      in SOV3Tensor (Key.toText k) shape size off : go rest (off + size)

-- | A tensor's directory entry by name.
sov3Tensor :: SOV3 -> Text -> Maybe SOV3Tensor
sov3Tensor sv n = case filter ((== n) . stName) (svTensors sv) of
  (t : _) -> Just t
  []      -> Nothing

-- | Unpack packed bytes into trit values ({0,1,2} as floats).
--
-- 位序已与训练侧权威实现 @sov_checkpoint._unpack_trits@ 逐 trit 对拍一致
-- （@_pack_trits@ 展开为 @t0·81 + t1·27 + t2·9 + t3·3 + t4@，高位优先）。
unpackTrits :: BS.ByteString -> Int -> [Float]
unpackTrits bytes n = map fromIntegral (unpackTritsInt bytes n)

-- | 同 'unpackTrits'，但直接给 'Int' —— 省掉 @Float@ 装箱与 @map round@。
-- 值域只有 {0,1,2}，走 @Float@ 纯属浪费。
unpackTritsInt :: BS.ByteString -> Int -> [Int]
unpackTritsInt bytes n = take n (concatMap digits (BS.unpack bytes))
  where
    -- ⚠️ 位序：**最低位优先**，powers [1, 3, 9, 27, 81]。
    --
    -- 对应训练侧写 .sov 的路径 @scripts/run_train._pack_trits_fast@：
    --   @powers = [1, 3, 9, 27, 81]@  ⟹  @byte = t0*1 + t1*3 + t2*9 + t3*27 + t4*81@
    -- 与 @sov_checkpoint._pack_trits@（[81,27,9,3,1]）**相反** —— 本项目 checkpoint
    -- 由 run_train.py 写出，故必须用升序。
    -- 已用 @artifacts/checkpoints/<tag>.pt@（未打包 state_dict, bfloat16）独立验证：
    -- 升序打包与 .sov 的 data/0 **逐字节全等**，降序不符。
    digits b = let w = fromIntegral b :: Int
               in [ (w `div` p) `mod` 3 | p <- [1, 3, 9, 27, 81] ]

-- | A tensor's weights, dequantised from its trits.
sov3TensorFloats :: SOV3 -> Text -> Maybe [Float]
sov3TensorFloats sv name = do
  t <- sov3Tensor sv name
  let bytes = BS.take (stSize t) (BS.drop (stStart t) (svImage sv))
      elems = product (stShape t)
  pure (unpackTrits bytes (if elems == 0 then stSize t * 5 else elems))

--------------------------------------------------------------------------------
-- torch.save 的 ZIP 容器
--
-- 训练后的 checkpoint（如 @20260721-033421_step31000.sov@）**不是**裸 SOV3，
-- 而是 @torch.save@ 的 ZIP：magic @"PK\003\004"@，内含
--
-- > <name>/data.pkl           pickle：张量名（按出现顺序）
-- > <name>/data/0 .. data/N   各 storage 的裸字节
-- > <name>/.format_version 等
--
-- 实测**全部条目都是 Stored**（method 0，Size == Length），所以无需 zlib：
-- 顺序扫描本地文件头（30 字节固定 + name + extra）即可切出数据。
-- 张量的 5-trit/byte 编码与裸 SOV3 完全一致（token_emb.weight 恒为
-- 1536*1440/5 = 442368 字节），因此 'unpackTrits' 可直接复用。
--------------------------------------------------------------------------------

-- | ZIP 里的一个条目（只支持 Stored）。
data TZEntry = TZEntry
  { tzPath :: String           -- ^ 例如 "20260721-033421_step31000/data/0"
  , tzData :: BS.ByteString
  } deriving (Show, Eq)

le16 :: BS.ByteString -> Int -> Int
le16 b p = fromIntegral (BS.index b p) + 256 * fromIntegral (BS.index b (p + 1))

-- | 读 torch.save 的 ZIP 容器（遇到中央目录即停）。
--
-- torch.save 的条目带 data descriptor（通用标志位 bit 3，实测 flags = 0x0808）。
-- 按 ZIP 规范此时本地头的 crc/csize/usize 全为 0，真实尺寸只在数据后的 descriptor 里。
-- 所以这里不信任 csize：从 dataAt 起扫描下一个本地头或中央目录，两者之间即裸数据。
loadTorchZip :: FilePath -> IO (Either String [TZEntry])
loadTorchZip path = fmap parseZip (BS.readFile path)

parseZip :: BS.ByteString -> Either String [TZEntry]
parseZip img = go 0 []
  where
    n = BS.length img
    go p acc
      | p + 30 > n = Right (reverse acc)
      | BS.take 4 (BS.drop p img) /= "PK\003\004" = Right (reverse acc)
      | otherwise =
          let method   = le16 img (p + 8)
              namelen  = le16 img (p + 26)
              extralen = le16 img (p + 28)
              nameAt   = p + 30
              dataAt   = nameAt + namelen + extralen
              name     = map (toEnum . fromIntegral)
                           (BS.unpack (BS.take namelen (BS.drop nameAt img)))
              stop     = nextHeader dataAt
          in if method /= 0
               then Left ("torchzip: " ++ name ++ " is not Stored (method="
                          ++ show method ++ "); needs zlib")
               else if dataAt > n || stop < dataAt
                 then Left ("torchzip: " ++ name ++ " runs past EOF")
                 else let end = trimDescriptor (stop - dataAt) stop
                      in go stop (TZEntry name (BS.take end (BS.drop dataAt img)) : acc)

    -- 条目带 data descriptor 时，其 16 字节（PK\a\b + crc + csize + usize）会落在
    -- 扫描出的 stop 之前，需剔除。实测 torch.save 的 data/0 是 442384 = 442368 + 16。
    trimDescriptor len stop
      | len >= 16 && BS.take 4 (BS.drop (stop - 16) img) == "PK\a\b" = len - 16
      | otherwise = len

    nextHeader from =
      case [ q | q <- [from .. n - 4]
               , let s = BS.take 4 (BS.drop q img)
               , s == "PK\003\004" || s == "PK\001\002" ] of
        (q : _) -> q
        []      -> n

-- | ZIP 条目索引：名字 → (数据偏移, 数据长度)。**只记位置，不搬数据**。
--
-- ⚡ 动机：'loadTorchZip' 会把每个条目的数据都切出来（253 MB 全量驻留），
-- 不适合「逐层取、用完即弃」的流式前向。这里只记录偏移/长度，
-- 内存开销 O(条目数)（约 324 条 ≈ 10 KB），数据用 'sovSlice' 按需切片。
--
-- 条目是 Stored（未压缩），所以切片就是纯字节视图，无需解码、无需 PyTorch。
indexZip :: BS.ByteString -> [(String, Int, Int)]
indexZip img = go 0 []
  where
    n = BS.length img
    go p acc
      | p + 30 > n = reverse acc
      | BS.take 4 (BS.drop p img) /= "PK\003\004" = reverse acc
      | otherwise =
          let method   = le16 img (p + 8)
              namelen  = le16 img (p + 26)
              extralen = le16 img (p + 28)
              nameAt   = p + 30
              dataAt   = nameAt + namelen + extralen
              name     = map (toEnum . fromIntegral)
                           (BS.unpack (BS.take namelen (BS.drop nameAt img)))
              stop     = nextHeader dataAt
              end      = trimDescriptor (stop - dataAt) stop
          in if method /= 0 || dataAt > n || stop < dataAt
               then go stop acc      -- 非 Stored / 越界：跳过（保持索引健壮）
               else go stop ((name, dataAt, end) : acc)

    trimDescriptor len stop
      | len >= 16 && BS.take 4 (BS.drop (stop - 16) img) == "PK\a\b" = len - 16
      | otherwise = len

    nextHeader from =
      case [ q | q <- [from .. n - 4]
               , let s = BS.take 4 (BS.drop q img)
               , s == "PK\003\004" || s == "PK\001\002" ] of
        (q : _) -> q
        []      -> n

-- | 按索引项从镜像里取数据（零拷贝视图）。
sovSlice :: BS.ByteString -> (String, Int, Int) -> BS.ByteString
sovSlice img (_, off, len) = BS.take len (BS.drop off img)

-- | 按名字（后缀匹配，如 @/data/0@）取一个条目。
sovLookup :: [(String, Int, Int)] -> String -> Maybe (String, Int, Int)
sovLookup idx suffix = case [ e | e@(nm, _, _) <- idx, suffix `isSuffixOf` nm ] of
  (e : _) -> Just e
  []      -> Nothing

-- | 按条目路径取数据（如 @<name>/data/0@）。
tzEntry :: [TZEntry] -> String -> Maybe TZEntry
tzEntry es n = case filter ((== n) . tzPath) es of
  (e : _) -> Just e
  []      -> Nothing

-- | 从 @data.pkl@ 里按出现顺序提取张量名（去重保序）。
-- 只做 ASCII 串扫描，**不解析 pickle 语义** —— 名字与 @data/N@ 的严格对应仍需按
-- storage key 对齐；实践中可用尺寸唯一匹配（如 token_emb.weight 恒为 442368）。
tzNames :: BS.ByteString -> [String]
tzNames bs = dedup [ s | s <- runs, isName s ]
  where
    runs = splitWords (map (\w -> toEnum (fromIntegral w :: Int) :: Char) (BS.unpack bs))
    splitWords [] = []
    splitWords cs = let w = takeWhile ok cs
                        rest = drop (length w) cs
                    in w : splitWords (dropWhile (not . ok) rest)
    ok c = not (isSpace c) && (isAlphaNum c || c `elem` ("._" :: String))
    isName s = '.' `elem` s && length s >= 6
    dedup = go []
    go _ [] = []
    go seen (x : xs) | x `elem` seen = go seen xs
                     | otherwise     = x : go (x : seen) xs
