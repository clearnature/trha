{-# LANGUAGE OverloadedStrings #-}

-- | 沙箱命令的数据类型：'SandboxAction'（子命令）、'ExperimentArgs'、
-- 'SandboxConfigPatch'（配置补丁）。
--
-- 从 "Core.Sandbox" 下沉：Core.Sandbox 与 Core.Sandbox.Run 都要用它们，
-- 留任何一边都会与对方的 import 成环。
module Core.Sandbox.Types
  ( SandboxAction(..)
  , ExperimentArgs(..)
  , SandboxConfigPatch(..)
  ) where

import Data.Aeson (FromJSON(..), withObject, (.:), (.:?), (.!=))
import Infrastructure.Sandbox
import Data.Text (Text)

data SandboxAction
  = SandboxStatus Bool       -- ^ True = JSON (machine-readable)
  | SandboxProbe (Maybe String)
  | SandboxPolicyGet (Maybe String)
  | SandboxPolicySet String FilePath
  | SandboxExec String [String]
  | SandboxAudit (Maybe String)
  | SandboxRunner FilePath FilePath Text (Maybe String) Text
  | SandboxConfigAction SandboxConfigPatch Bool
  | SandboxScopes
  | SandboxExperiment ExperimentArgs Bool  -- ^ Batch run; True = JSON output
  deriving (Eq, Show)

-- | Parsed options for @trha sandbox experiment@ (T2.7's client face).
data ExperimentArgs = ExperimentArgs
  { eaId          :: String
  , eaRoot        :: FilePath
  , eaBaseline    :: FilePath
  , eaVariants    :: [String]        -- ^ repeated --variant
  , eaSeeds       :: [Int]          -- ^ repeated --seed
  , eaCommand     :: [String]       -- ^ -- separated argv (no shell string)
  , eaConcurrency :: Int            -- ^ 1..16, scheduler clamps again
  , eaRetries     :: Int            -- ^ 0..4
  , eaOutput      :: Maybe FilePath -- ^ default ~/.trha/experiments/<id>.json
  } deriving (Eq, Show)

data SandboxConfigPatch = SandboxConfigPatch
  { cfgEnabled :: Maybe Bool
  , cfgPolicy  :: Maybe String
  , cfgNetwork :: Maybe String
  , cfgScratch :: Maybe String
  , cfgPids    :: Maybe Int
  , cfgMemory  :: Maybe Int
  , cfgWall    :: Maybe Int
  , cfgDenyDirs  :: Maybe [Text]
    -- ^ `--deny-dirs a,b`: replaces the masked credential directories.
    -- `--deny-dirs ""` is an explicit empty list (un-masks everything) —
    -- distinct from not passing the flag at all, which keeps the current value.
  , cfgDenyFiles :: Maybe [Text]
  } deriving (Eq, Show)
