{-# LANGUAGE OverloadedStrings #-}

-- | capability SID 派生（T4.2，纯 Haskell，无 FFI）。
--
-- 对齐 @deepseek-harness/packages/sandbox/sandbox-windows-acl/src/workspace-sid.ts@
-- 的设计意图：每个可写根派生成一个 /确定性/ 的 @S-1-4-x-y@ 能力 SID。
--
-- 同一 workspace 跨会话、跨进程重启都派生出同一个 SID，因此它的 ACE 只需在
-- 机器上物化一次；令牌的 restricting SID 列表带上它，@WRITE_RESTRICTED@ 才会
-- 对那棵目录树放行。SID 字符串本身不是秘密——它的权力完全由「引用它的 ACE」
-- 定义，而那些 ACE 只存在于 workspace 树和本会话的私有 temp 目录上。
--
-- 与参考实现的差异：用 FNV-1a 64 而非 SHA-256，避免为 8 字节摘要引入加密库。
-- 判据是「确定性 + 子权威分布均匀」，不是抗碰撞——SID 不是凭据。
module Infrastructure.Sandbox.Win32.Sid
  ( workspaceWriteSid
  , tempWriteSid
  , isValidSid
  ) where

import Data.Bits ((.&.), shiftR, xor)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)

-- | SID 子权威是 30 位无符号，上限 @2^30 - 1@。
maxSubAuthority :: Word64
maxSubAuthority = 2 ^ (30 :: Int) - 1

-- | FNV-1a 64 位：确定性、无需依赖、分布均匀。
fnv1a64 :: Text -> Word64
fnv1a64 = T.foldl' step 0xcbf29ce484222325
  where
    step h c = (h `xor` fromIntegral (fromEnum c)) * 0x100000001b3

-- | 从 64 位摘要取出两个 30 位子权威（都 >= 1，避开 0）。
subAuthorities :: Word64 -> (Word64, Word64)
subAuthorities digest =
  let low = digest .&. maxSubAuthority
      high = (digest `shiftR` 30) .&. maxSubAuthority
      clamp n = if n == 0 then 1 else n
   in (clamp low, clamp high)

-- | workspace 的写能力 SID：@S-1-4-{a}-{b}@（两个子权威）。
workspaceWriteSid :: Text -> Text
workspaceWriteSid canonicalRoot =
  let (a, b) = subAuthorities (fnv1a64 canonicalRoot)
   in T.concat ["S-1-4-", tshow a, "-", tshow b]

-- | 私有 temp 目录的写能力 SID：@S-1-4-{a}-{b}-1@（三个子权威）。
--
-- 第三个子权威 @-1@ 做域分隔：temp SID 的形状与任何 workspace SID 都不可能重叠
-- （workspace 只有两个子权威）。temp 与 workspace 用不同身份，否则兄弟会话能
-- 互相写对方的 temp 树。
tempWriteSid :: Text -> Text
tempWriteSid canonicalDir =
  let (a, b) = subAuthorities (fnv1a64 ("temp\NUL" <> canonicalDir))
   in T.concat ["S-1-4-", tshow a, "-", tshow b, "-1"]

-- | 校验派生结果符合 @S-1-4-…@ 形状（供测试与调用方断言）。
isValidSid :: Text -> Bool
isValidSid sid = case T.splitOn "-" sid of
  ("S" : "1" : "4" : rest) -> not (null rest) && all numeric rest
  _ -> False
  where
    numeric t = not (T.null t) && T.all (`elem` ("0123456789" :: String)) t

tshow :: Show a => a -> Text
tshow = T.pack . show
