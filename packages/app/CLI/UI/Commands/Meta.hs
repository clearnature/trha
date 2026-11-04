{-# LANGUAGE OverloadedStrings #-}

-- | 元信息类命令：帮助、退出、停止确认、关于。
--
-- 领域模块之一（约定见 "UI.Commands.Env"）：认领自己的分支返回 @Just@，
-- 其余返回 @Nothing@；@UI.Commands.executeCommand@ 用 'dispatch' 串起各域。
module UI.Commands.Meta
  ( runMeta
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (getCurrentDirectory, getHomeDirectory)
import System.FilePath ((</>))

import Bridge.Scheduler (fetchServiceStatus)
import UI.Commands.Env (CmdEnv(..))
import UI.Commands.Registry (Command(..), registryHelp)
import UI.I18n (tr)

-- | 只认领与「界面自身信息」有关的分支。
runMeta :: CmdEnv -> Command -> Maybe (IO (Maybe Text))
runMeta env Help = Just (pure (Just (registryHelp (ceLang env))))
runMeta _ Quit = Just (pure Nothing)
runMeta env StopRequest =
  Just . pure . Just $
    tr (ceLang env) "This stops the kernel and scheduler and exits. Type /stop confirm to proceed."
runMeta _ StopConfirmed = Just (pure Nothing)
runMeta env About = Just $ do
  cwd <- getCurrentDirectory
  home <- getHomeDirectory
  (lspLines, mcpLines) <- fetchServiceStatus (ceBridge env)
  pure . Just . T.unlines $
    [ "trha · " <> tr (ceLang env) "agent harness"
    , tr (ceLang env) "Working directory: " <> T.pack cwd
    , tr (ceLang env) "Config: " <> T.pack (home </> ".trha")
    , tr (ceLang env) "LSP: " <> T.intercalate ", " lspLines
    , tr (ceLang env) "MCP: " <> T.intercalate ", " mcpLines
    ]
runMeta _ _ = Nothing
