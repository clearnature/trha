{-# LANGUAGE OverloadedStrings #-}

-- | 信息类斜杠命令：@/help@、@/status@、@/copy@、@/update@。
--
-- 从 "UI.Brick.Slash" 拆出（认领式分派）。
module UI.Brick.Slash.Info
  ( handleInfoSlash
  ) where

import Brick (EventM, get, modify)
import Brick.BChan (writeBChan)
import Control.Concurrent.Async (async)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.FilePath ((</>))
import System.Directory (getCurrentDirectory, getTemporaryDirectory)
import System.Exit (ExitCode(..))
import System.Process (readCreateProcessWithExitCode, proc)

import UI.Brick.Draw.Status (statusLine)
import UI.Brick.MessageOps (appendMsg, now)
import UI.Brick.Selection (copyToClipboard)
import UI.Brick.Slash.Ctx (CmdCtx(..))
import UI.Brick.Toast (showToast)
import UI.Commands.Registry (helpTextFor)
import UI.Dialog (Dialog(..), stackPush)
import UI.Event (AppEvent(..))
import UI.I18n (tr)
import UI.State
  ( AppState(..), ChatMessage(..), ResourceName, appLang, appMessages, mkMsg )

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
  -- /update（无参）保持文本比对；/update pull 是快进式写操作，先确认。
  _ | (cxCmd cx) == "/update pull" -> Just $ slashUpdatePullConfirm cx
  _ -> Nothing

-- | @/update pull@：快进式 @git pull --ff-only@ 前先确认（通用确认槽）。
slashUpdatePullConfirm :: CmdCtx -> EventM ResourceName AppState ()
slashUpdatePullConfirm cx = do
  let chan = cxChan cx
      lang = cxLang cx
      act = do
        cwd <- getCurrentDirectory
        (code, out, err) <- readCreateProcessWithExitCode
                              (proc "git" ["-C", cwd, "pull", "--ff-only"]) ""
        let body = T.pack (if null out then err else out)
            firstLine = T.strip (head (T.lines body))
            msg = case code of
              ExitSuccess   -> "git pull: " <> firstLine
              ExitFailure n -> "git pull failed (" <> T.pack (show n) <> "): " <> T.take 200 (T.pack err)
        writeBChan chan (EvToast msg)
  modify $ \s -> s
    { appDialogs = stackPush (DialogConfirm (tr lang "Pull origin/main and fast-forward this checkout?") 1)
                             (appDialogs s)
    , appPendingConfirm = Just ("update pull", act) }
