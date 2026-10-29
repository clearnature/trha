{-# LANGUAGE OverloadedStrings #-}

-- | Landlock support probe (T1.3, optional).
--
-- bwrap already provides the filesystem boundary. Landlock would add
-- syscall-level confinement *on top*, but its rules must be installed by the
-- target process itself (@landlock_create_ruleset@ + @landlock_restrict_self@),
-- which needs a launcher — the same shape as the Capsicum/pledge launchers in
-- P5. Until that launcher exists this module only *reports* support, so the
-- capability (or its absence) is visible in @trha sandbox status@ instead of
-- being silently missing.
--
-- The ABI number is inferred from the kernel release, not queried via the
-- syscall (a variadic FFI call would need a C shim): it is a hint for humans,
-- and the note says so.
module Infrastructure.Sandbox.Landlock
  ( LandlockSupport(..)
  , detectLandlock
  , abiForRelease
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

data LandlockSupport = LandlockSupport
  { llEnabled :: Bool
    -- ^ @landlock@ appears in @/sys/kernel/security/lsm@.
  , llAbi     :: Maybe Int
    -- ^ Kernel release hint (see 'abiForRelease'); not a syscall query.
  , llNote    :: Text
  } deriving (Eq, Show)

-- | Read the LSM list and the kernel release; never throws.
detectLandlock :: IO LandlockSupport
detectLandlock = do
  lsms <- lsmModules
  release <- kernelRelease
  let enabled = maybe False (elem "landlock") lsms
      abi = if enabled then release >>= abiForRelease else Nothing
  pure LandlockSupport
    { llEnabled = enabled
    , llAbi = abi
    , llNote = note enabled abi
    }

note :: Bool -> Maybe Int -> Text
note False _ =
  "landlock: not enabled in this kernel's LSM list (bwrap still provides the fs boundary)"
note True (Just n) =
  "landlock: enabled, kernel ABI ~" <> T.pack (show n)
    <> " (rules need a launcher; not enforced yet)"
note True Nothing =
  "landlock: enabled, ABI unknown from the kernel release (rules need a launcher)"

lsmModules :: IO (Maybe [Text])
lsmModules = do
  raw <- try (TIO.readFile "/sys/kernel/security/lsm") :: IO (Either IOException Text)
  pure $ case raw of
    Left _ -> Nothing
    Right txt -> Just (map T.strip (T.splitOn "," (T.strip txt)))

kernelRelease :: IO (Maybe (Int, Int))
kernelRelease = do
  raw <- try (TIO.readFile "/proc/sys/kernel/osrelease") :: IO (Either IOException Text)
  pure $ case raw of
    Left _ -> Nothing
    Right txt -> parseRelease (T.unpack (T.strip txt))

-- | @\"6.8.0-51-generic\"@ → @Just (6, 8)@.
parseRelease :: String -> Maybe (Int, Int)
parseRelease raw = case mapM readInt (take 2 (splitDots raw)) of
  Just [maj, minr] -> Just (maj, minr)
  _ -> Nothing
  where
    splitDots s = case break (== '.') s of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitDots rest
    readInt s = case reads s :: [(Int, String)] of
      [(n, "")] -> Just n
      _ -> Nothing

-- | Landlock ABI per kernel release (5.13 → 1, 6.2 → 2, 6.7 → 3, 6.10 → 4,
-- 6.12 → 5). Anything newer keeps the highest known value.
abiForRelease :: (Int, Int) -> Maybe Int
abiForRelease release
  | release >= (6, 12) = Just 5
  | release >= (6, 10) = Just 4
  | release >= (6, 7) = Just 3
  | release >= (6, 2) = Just 2
  | release >= (5, 13) = Just 1
  | otherwise = Nothing
