{-# LANGUAGE OverloadedStrings #-}

-- | 命令执行的共享环境。
--
-- 从 @UI.Commands.executeCommand@ 的签名
-- @Lang -> SchedulerBridge -> IORef (Maybe SessionId) -> IORef Text -> …@
-- 抽出：各领域模块（Meta/Session/Model/Context/Integration/Config/Plan/Tools）
-- 都接收同一个 'CmdEnv'，而不是各自重复四个参数。
--
-- 领域模块的约定——每个模块导出
--
-- > runXxx :: CmdEnv -> Command -> Maybe (IO (Maybe Text))
--
-- 认领的分支返回 @Just@，其余返回 @Nothing@；'dispatch' 按顺序取第一个
-- 认领者。新增命令只改对应领域模块（加一个等式）+ Registry 注册 + I18n 文案，
-- 不再动 @UI.Commands@ 的 1500 行单体。
module UI.Commands.Env
  ( CmdEnv(..)
  , dispatch
  ) where

import Control.Applicative ((<|>))
import Data.IORef (IORef)
import Data.Text (Text)

import Bridge.Scheduler (SchedulerBridge)
import Core.Types (SessionId)
import UI.Commands.Registry (Command)
import UI.I18n (Lang)

-- | 命令执行期间不变的一组句柄。
data CmdEnv = CmdEnv
  { ceLang    :: Lang
    -- ^ 界面语言（决定提示文案）
  , ceBridge  :: SchedulerBridge
    -- ^ 调度层 HTTP 桥
  , ceSession :: IORef (Maybe SessionId)
    -- ^ 当前会话；@/new@ 等命令会写它
  , ceModel   :: IORef Text
    -- ^ 当前模型选择；@/model @xxx@ 会写它
  }

-- | 依次尝试各领域模块，第一个认领的分支胜出。
dispatch
  :: [CmdEnv -> Command -> Maybe (IO (Maybe Text))]
  -> CmdEnv
  -> Command
  -> Maybe (IO (Maybe Text))
dispatch handlers env cmd =
  foldr (<|>) Nothing (map (\h -> h env cmd) handlers)
