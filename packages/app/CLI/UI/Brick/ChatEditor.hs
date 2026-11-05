{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 编辑器交互：把编辑器内容提交为消息（commitEditor）、用 $EDITOR 外挂编辑
-- （editExternally，期间挂起 TUI）。
--
-- 从 "UI.Brick.ChatSubmit" 拆出。与「提交入口」（submitSkill / handleSubmit /
-- handleChat）分开：这里只关心编辑器本身，不关心这条消息最终发给谁。
module UI.Brick.ChatEditor
  ( commitEditor, editExternally
  ) where

import Brick (EventM, get, modify, suspendAndResume)
import Brick.Widgets.Edit (editorText)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, catch, try)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)

import UI.Brick.Input (editorValue)
import UI.Brick.Toast (showToast)
import UI.InputHistory (appendHistory, histCommit)
import UI.State (AppState(..), ResourceName(..))

commitEditor :: Text -> EventM ResourceName AppState ()
commitEditor input = do
  liftIO (appendHistory input)
  modify $ \s -> s { appInput = editorText InputArea (Just 1) ""
                   , appHist = histCommit input (appHist s)
                   , appComp = Nothing
                   , appPalette = Nothing }

-- | Pass an event through to the brick editor (default editing keys:
-- alt+enter inserts a newline; cursor movement; pastes).
-- | editDefaultKey / cursorRow 见 UI.Brick.ChatKeys。

-- | Toggle the most recent tool card (ctrl+o, or enter on empty input).
-- | ctrl+e: edit the composer in @$EDITOR@.  The TUI suspends while the
-- editor owns the terminal, then the saved text replaces the composer.

editExternally :: EventM ResourceName AppState ()
editExternally = do
  st <- get
  let text = editorValue st
  (path, ed) <- liftIO $ do
    tmp <- getTemporaryDirectory
    (path, h) <- openTempFile tmp "trha-edit.txt"
    TIO.hPutStr h text
    hClose h
    e <- do
      v <- lookupEnv "EDITOR"
      case v of
        Just e' | not (null e') -> pure e'
        _ -> do
          v2 <- lookupEnv "VISUAL"
          case v2 of
            Just e2 | not (null e2) -> pure e2
            -- Windows 原生环境无 vi（tui-port L80 同款死角）：否则
            -- readProcess 抛 IOException 且 putMVar 不执行，takeMVar
            -- 永久阻塞把 TUI 挂死。
            _ -> do
              mSpec <- lookupEnv "ComSpec"
              pure (maybe "vi" (const "notepad") mSpec)
    pure (path, e)
  resultVar <- liftIO newEmptyMVar
  suspendAndResume $ do
    -- editor 缺失/异常也要 putMVar，否则 takeMVar 阻塞挂死 TUI。
    r <- try (readProcessWithExitCode ed [path] "")
    putMVar resultVar $ case (r :: Either IOException (ExitCode, String, String)) of
      Right (code, _, _) -> code
      Left _ex           -> ExitFailure 127  -- command-not-found 惯例
    pure st
  code <- liftIO (takeMVar resultVar)
  body <- liftIO $ TIO.readFile path `catch` \(_ :: IOException) -> pure text
  liftIO $ removeFile path `catch` \(_ :: IOException) -> pure ()
  case code of
    ExitSuccess ->
      modify $ \s -> s { appInput = editorText InputArea (Just 1) (T.stripEnd body) }
    ExitFailure n ->
      showToast ("editor exited " <> T.pack (show n))

-- | Run one posture action (cycle / yolo / set) and reflect the answer in
-- the footer.  Modes are session state: without a session there is nothing
-- to switch.
-- | modeAction 见 UI.Brick.Apply。

-- | Show a transient notice and schedule its dismissal.  The stamp keeps a
-- late timer from clearing a newer toast.
-- | showToast 见 UI.Brick.Toast。

-- | Pull the session's posture (after creation/restore).
