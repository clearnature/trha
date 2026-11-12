{-# LANGUAGE OverloadedStrings #-}

-- | 工具类斜杠命令：@/shell@、@/diff@、@/stats@、@/permissions@。
--
-- 从 "UI.Brick.Slash" 拆出（认领式分派）。
module UI.Brick.Slash.Tools
  ( handleToolsSlash
  ) where

import Brick (EventM, get, modify)
import Brick.BChan (writeBChan)
import Control.Concurrent.Async (async)
import Control.Monad (forM_, void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode(..))
import System.Process (readCreateProcessWithExitCode, proc)

import Bridge.Scheduler (fetchPermissions, setPermissions)
import UI.Brick.Apply (openSettingsPanelOn)
import UI.Brick.MessageOps (appendMsg, now)
import UI.Brick.RunControl (runShellCommand)
import UI.Brick.Slash.Ctx (CmdCtx(..))
import UI.Dialog (Dialog(..), stackPush)
import UI.Event (AppEvent(..))
import UI.I18n (tr)
import UI.Render.ToolCard (ToolCard(..), ToolStatus(..))
import UI.State (AppState(..), ResourceName, SettingsTab(..), appLang, mkMsg, toolMsg)

handleToolsSlash :: CmdCtx -> Maybe (EventM ResourceName AppState ())
handleToolsSlash cx
  | cmd == "/shell" || "/shell " `T.isPrefixOf` cmd = Just $ do
      let arg = T.strip (T.drop (T.length "/shell") (cxInput cx))
      if T.null arg
        then appendMsg (mkMsg "error" (tr (appLang (cxState cx)) "Usage: /shell <cmd>") (cxTime cx))
        else runShellCommand arg
  -- /stats：复用设置面板现成的 TabStats 图形页（批次三 R1），不再打印文本表。
  | cmd == "/stats" = Just $ openSettingsPanelOn TabStats
  -- /permissions：异步拉取规则并打开管理对话框
  -- （Enter 循环 kind：allow → ask → deny；d 删除；Esc 关闭。变更即 PUT 持久化）。
  | cmd == "/permissions" = Just $ do
      let chan = cxChan cx
      modify $ \s -> s { appDialogs = stackPush (DialogPermissions [] 0) (appDialogs s)
                       , appStatus = tr (appLang (cxState cx)) "Loading permissions…" }
      void . liftIO . async $ do
        r <- fetchPermissions (cxBridge cx)
        let pairs = case r of
              Right vs -> Right (mapMaybe ruleOf vs)
              Left e   -> Left e
        writeBChan chan (EvPermissionsRules pairs)
  -- /diff：本地 git，快；直接同步跑，输出以 diff 卡片呈现（批次二 D：
  -- 不再落 4000 字纯文本兜底——diffWidget 渲染器现成）。
  | cmd == "/diff" = Just $ do
      -- 本地 git 同步执行（瞬时完成），不设 Running 状态栏：完成后无处复位。
      st <- get
      t <- liftIO now
      cwd <- liftIO getCurrentDirectory
      (code, out, err) <- liftIO $ readCreateProcessWithExitCode
                            (proc "git" ["-C", cwd, "diff", "--no-color"]) ""
      let ls = T.lines (T.pack (out <> err))
          status = case code of
            ExitSuccess   -> ToolSucceeded
            ExitFailure n -> ToolFailed (T.pack (show n))
          card = ToolCard "diff" [] (Just status) Nothing ls "diff"
      if null ls || T.null (T.concat ls)
        then appendMsg (mkMsg "system" (tr (appLang st) "No uncommitted changes (git diff).") t)
        else appendMsg (toolMsg "tool" card t)
  | otherwise = Nothing
  where cmd = cxCmd cx

-- | 规则 JSON → (kind, pattern) 对；缺字段的规则丢弃。
ruleOf :: Value -> Maybe (T.Text, T.Text)
ruleOf (Object o) = do
  k <- strF "kind" o
  p <- strF "pattern" o
  pure (k, p)
ruleOf _ = Nothing

strF :: T.Text -> KM.KeyMap Value -> Maybe T.Text
strF k o = case KM.lookup (AK.fromText k) o of
  Just (Data.Aeson.String t) -> Just t
  _ -> Nothing
