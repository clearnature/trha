{-# LANGUAGE OverloadedStrings #-}

-- | 信息类斜杠命令：@/help@、@/status@、@/copy@。
--
-- 从 "UI.Brick.Slash" 拆出（认领式分派）。
module UI.Brick.Slash.Info
  ( handleInfoSlash
  ) where

import Brick (EventM, get)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.FilePath ((</>))
import System.Directory (getTemporaryDirectory)

import UI.Brick.Draw.Status (statusLine)
import UI.Brick.MessageOps (appendMsg, now)
import UI.Brick.Selection (copyToClipboard)
import UI.Brick.Slash.Ctx (CmdCtx(..))
import UI.Brick.Toast (showToast)
import UI.Commands.Registry (helpTextFor)
import UI.I18n (tr)
import UI.State
  ( AppState, ChatMessage(..), ResourceName, appLang, appMessages, mkMsg )

handleInfoSlash :: CmdCtx -> Maybe (EventM ResourceName AppState ())
handleInfoSlash cx = case cxCmd cx of
  "/help" ->
    Just $ appendMsg (mkMsg "system" (helpTextFor (appLang (cxState cx))) (cxTime cx))
  "/status" ->
    Just $ appendMsg (mkMsg "system" (statusLine (cxState cx)) (cxTime cx))
  "/copy" -> Just $ do
    st2 <- get
    t2 <- liftIO now
    case [ m | m <- reverse (appMessages st2), msgRole m == "assistant"
             , not (T.null (msgContent m)) ] of
      (m : _) -> do
        ok <- liftIO $ copyToClipboard (msgContent m)
        if ok
          then showToast (tr (cxLang cx) "Copied to clipboard")
          else do
            tmp <- liftIO getTemporaryDirectory
            let path = tmp </> "trha-copy.txt"
            liftIO $ TIO.writeFile path (msgContent m)
            appendMsg (mkMsg "system"
              (tr (cxLang cx) "Clipboard unavailable; wrote " <> T.pack path) t2)
      [] -> appendMsg (mkMsg "system" (tr (cxLang cx) "No assistant message to copy") t2)
  _ -> Nothing
