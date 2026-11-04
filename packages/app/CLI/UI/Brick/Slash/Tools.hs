{-# LANGUAGE OverloadedStrings #-}

-- | 工具类斜杠命令：@/shell@。
--
-- 从 "UI.Brick.Slash" 拆出（认领式分派）。
module UI.Brick.Slash.Tools
  ( handleToolsSlash
  ) where

import Brick (EventM)
import Data.Text (Text)
import qualified Data.Text as T

import UI.Brick.MessageOps (appendMsg)
import UI.Brick.RunControl (runShellCommand)
import UI.Brick.Slash.Ctx (CmdCtx(..))
import UI.I18n (tr)
import UI.State (AppState, ResourceName, appLang, mkMsg)

handleToolsSlash :: CmdCtx -> Maybe (EventM ResourceName AppState ())
handleToolsSlash cx
  | cmd == "/shell" || "/shell " `T.isPrefixOf` cmd = Just $ do
      let arg = T.strip (T.drop (T.length "/shell") (cxInput cx))
      if T.null arg
        then appendMsg (mkMsg "error" (tr (appLang (cxState cx)) "Usage: /shell <cmd>") (cxTime cx))
        else runShellCommand arg
  | otherwise = Nothing
  where cmd = cxCmd cx
