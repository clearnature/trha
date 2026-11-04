{-# LANGUAGE OverloadedStrings #-}

-- | 调度层桥接的核心：'SchedulerBridge' 句柄与它的构造。
--
-- 从 "Bridge.Scheduler" 拆出。各端点域（Session/Model/Plan/Admin）只依赖本模块
-- 拿 @SchedulerBridge@，彼此不互相 import；@Bridge.Scheduler@ 变成 re-export 聚合。
module Bridge.Scheduler.Core
  ( SchedulerBridge(..)
  , createSchedulerBridge
  ) where

import Config.Settings (resolveConfig)
import Core.Types
import Core.RunState (RuntimeEntry(..), Service(..), readRuntimeEntry)
import Core.HTTP
import Data.Text (Text)
import qualified Data.Text as T

data SchedulerBridge = SchedulerBridge
  { bridgeConfig :: CLIConfig
  , bridgeHTTP   :: HTTPClient
  }

-- | Create a new scheduler bridge
createSchedulerBridge :: CLIConfig -> IO SchedulerBridge
createSchedulerBridge config = do
  -- The scheduler publishes its live endpoint in ~/.trha/runtime.json; use it
  -- when the caller left the defaults in place.
  rt <- readRuntimeEntry Scheduler
  let cfg = case rt of
        Just e | configPort config == 28433 ->
          config
            { configHost  = T.pack (reHost e)
            , configPort  = rePort e
            , configToken = if T.strip (configToken config) == "dev-token"
                              then T.pack (reToken e)
                              else configToken config
            }
        _ -> config
  http <- createHTTPClient (configScheme cfg) (configHost cfg) (configPort cfg) (configToken cfg) (configTimeout cfg) (configProxy cfg)
  return $ SchedulerBridge cfg http

--------------------------------------------------------------------------------
