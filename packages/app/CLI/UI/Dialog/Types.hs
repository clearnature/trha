{-# LANGUAGE OverloadedStrings #-}

-- | 对话框的数据类型：栈元素、沙箱面板设置、审批选项、Esc 判定输入/输出。
--
-- 从 "UI.Dialog" 拆出——'Dialog' 有 12 个构造子，是那个模块最核心的部分；
-- Stack/Selection/Editing/Escape 四个子模块都只依赖这里，不反向依赖，
-- 所以先把类型沉下来，其余拆分才能做到单向依赖。
module UI.Dialog.Types
  ( Dialog(..)
  , SandboxSettings(..)
  , defaultSandboxSettings
  , sandboxApply
  , DialogStack
  , ApprovalOption(..)
  , EscFlags(..)
  , EscOutcome(..)
  ) where

import Brick.Escape (EscFlags(..), EscOutcome(..))
import Data.Text (Text)

import Core.SessionSummary (SessionSummary)
import Core.Types (AgentEntry, ModelInfo, ProviderInfo)
import UI.I18n (Lang)
import UI.ProviderPresets (Preset)
import UI.Render.Picker (PickerItem)
import UI.Skills (Skill)
import UI.Theme (Theme)

-- | Runtime sandbox knobs shown by @/sandbox@.  Enter persists through
-- PUT /api/sandbox/config: sandbox.yaml is written and the scheduler's
-- runtime switch flips, so the panel controls real execution.
data SandboxSettings = SandboxSettings
  { ssEnabled :: Bool
  , ssPolicy  :: Text   -- ^ workspace-write | read-only
  , ssNetwork :: Bool
  , ssScratch :: Text
  } deriving (Show, Eq)

defaultSandboxSettings :: SandboxSettings
defaultSandboxSettings = SandboxSettings
  { ssEnabled = False
  , ssPolicy = "workspace-write"
  , ssNetwork = False
  , ssScratch = "~/.trha/sandbox-scratch"
  }

-- | Apply the row at @index@ to the settings (enter on the /sandbox panel).
sandboxApply :: Int -> SandboxSettings -> SandboxSettings
sandboxApply 0 s = s { ssEnabled = not (ssEnabled s) }
sandboxApply 1 s = s { ssPolicy =
  if ssPolicy s == "workspace-write" then "read-only" else "workspace-write" }
sandboxApply 2 s = s { ssNetwork = not (ssNetwork s) }
sandboxApply _ s = s
-- | One modal overlay.  Selection dialogs carry their filtered list plus
-- the selected index; the command dialog carries the full registry (so
-- query edits can re-filter) plus the query and the selection.
data Dialog
  = DialogModels [ModelInfo] Text Int       -- ^ /models: all models, query, selected
  | DialogSessions [SessionSummary] Text Int -- ^ /sessions: all sessions, query, selected
  | DialogCommands [PickerItem] Text Int    -- ^ full registry, query, selected
  | DialogProviders [ProviderInfo] Int      -- ^ /provider: providers, selected
  | DialogPresets [Preset] Int             -- ^ /provider: preset vendors, selected
  | DialogSkills [Skill] Text Int           -- ^ /skills: skills, query, selected
  | DialogAgents [AgentEntry] Int           -- ^ /agents: session tree, selected
  | DialogThemes [Theme] Int                -- ^ /theme: built-in themes, selected
  | DialogLanguages [Lang] Int              -- ^ /language: interface languages, selected
  | DialogApproval Text String [Text] Int   -- ^ ask message, tool, args, selected
  | DialogConfirm Text Int                  -- ^ "always" confirmation, selected (0=yes)
  | DialogSandbox SandboxSettings Int       -- ^ /sandbox: settings, selected row
  deriving (Show, Eq)

-- | Stack of open dialogs; the head is the topmost (owns keys).
type DialogStack = [Dialog]
-- | Options offered by an approval card, in display order.
data ApprovalOption = ApprovalOnce | ApprovalAlways | ApprovalReject
  deriving (Show, Eq)

-- | MiMo's escape hierarchy: selection → dialog stack → shell →
-- autocomplete → approval.  Escape on the approval page is a reject
-- (MiMo's permission page binds escapeKey to reject); interrupting a
-- running session needs a double escape within 5 seconds — see
-- 'escPress'.
