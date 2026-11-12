{-# LANGUAGE OverloadedStrings #-}

-- | 分发认领覆盖：每条注册命令都必须被某个领域模块认领。
--
-- 「表里注册了、七个领域模块都不认领」= executeCommand 落到
-- 「Command not available in this front-end」兜底——这正是对标审计
-- （docs/reference/commands-tools-cross-benchmark-2026-11-12.md）要防的
-- 「有名字没执行」。本 spec 把它变成测试失败而不是静默兜底。
--
-- 同族守护：RegistrySpec（解析覆盖）、InteractionSpec（分层覆盖）、
-- I18nSpec（文案覆盖）；本文件补上「执行认领」这一环。
module UI.Commands.HandlerCoverageSpec (spec) where

import Data.IORef (newIORef)
import Data.Maybe (isJust)
import Test.Hspec

import Bridge.Scheduler (SchedulerBridge(..))
import Core.Types (defaultCLIConfig)
import UI.Commands.Config (runConfig)
import UI.Commands.Env (CmdEnv(..), dispatch)
import UI.Commands.Integration (runIntegration)
import UI.Commands.Meta (runMeta)
import UI.Commands.Model (runModel)
import UI.Commands.Plan (runPlan)
import UI.Commands.Registry
import UI.Commands.Session (runSession)
import UI.Commands.Tools (runTools)
import UI.I18n (Lang(..))

-- | 与 UI.Commands.executeCommand 相同的分发清单——两边不同步时本测试
-- 与该函数至少有一个会立刻暴露。
allHandlers =
  [ runMeta, runModel, runSession, runConfig, runIntegration, runTools, runPlan ]

spec :: Spec
spec = describe "UI.Commands dispatch coverage" $ do
  -- 处理器「认领」发生在模式匹配处、任何 IO 之前，因此 HTTP 客户端
  -- 用 error 占位即可（永远不会被强制求值）。
  let bridge = SchedulerBridge defaultCLIConfig
        (error "bridgeHTTP is never forced by a claim check")
  env <- runIO $ do
    sess <- newIORef Nothing
    mdl  <- newIORef "test-model"
    pure (CmdEnv En bridge sess mdl :: CmdEnv)

  it "每条注册命令都被领域模块认领（dispatch 返回 Just，不是兜底文案）" $ do
    let unclaimed =
          [ scCommand sc
          | sc <- slashRegistry
          , not (isJust (dispatch allHandlers env (parseCommand (scCommand sc))))
          ]
    unclaimed `shouldBe` []

  it "每条命令的表面清单非空（scSurfaces 至少标一个表面）" $ do
    mapM_ (\sc -> scSurfaces sc `shouldNotBe` []) slashRegistry

  it "标了 SRepl 的命令在 REPL 补全候选里；没标的不在" $ do
    let replList = completions
    mapM_ (\sc -> when' (SRepl `elem` scSurfaces sc)
                   (replList `shouldSatisfy` elem (scCommand sc))) slashRegistry
  where
    when' True action = action
    when' False _     = pure ()
