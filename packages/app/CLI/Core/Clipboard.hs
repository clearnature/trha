{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Clipboard image capture, shared by the TUI (@Ctrl+V@) and the
-- @/paste@ command.
--
-- Tries the usual helpers in order (wl-paste, xclip, pngpaste) and writes the
-- bytes under @~/.trha/paste/@; 'Nothing' when no helper yields a non-empty
-- file.  The path is what the composer attaches as @[image: …]@.
module Core.Clipboard
  ( saveClipboardImage
  , readClipboardText
  , copyToClipboard
  ) where

import Control.Exception (IOException, catch, try)
import System.Directory (createDirectoryIfMissing, getFileSize, getHomeDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readCreateProcessWithExitCode, readProcessWithExitCode, shell)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)

-- | 剪贴板里的**文本**（Shift+Insert）。没有 helper 时返回 'Nothing'。
--
-- 与图片分开：图片走文件字节，文本走 stdout；两者用不同的 helper 参数，
-- 混用会把图片二进制当成文本塞进输入框。
readClipboardText :: IO (Maybe Text)
readClipboardText = go
    [ "wl-paste -n -t text/plain"
    , "xclip -selection clipboard -o"
    , "xsel --clipboard --output"
    , "pbpaste"
    ]
  where
    go [] = pure Nothing
    go (c : cs) = do
      r <- try (readCreateProcessWithExitCode (shell c) "")
             :: IO (Either IOException (ExitCode, String, String))
      case r of
        Right (ExitSuccess, out, _)
          | not (T.null (T.strip (T.pack out))) -> pure (Just (T.pack out))
        _ -> go cs

-- | 把**文本**写进系统剪贴板；没有 helper 时返回 'False'。
--
-- 与读取共用同一族 helper（wl-copy/xclip/xsel/pbcopy）。REPL 与 TUI 的
-- @/copy@ 共用这一份实现（原本只在 UI.Brick.Selection，搬来 Core 让
-- 非 brick 路径也能用）。
copyToClipboard :: Text -> IO Bool
copyToClipboard txt = go
  [ ("wl-copy", [])
  , ("xclip", ["-selection", "clipboard"])
  , ("xsel", ["--clipboard", "--input"])
  , ("pbcopy", [])
  ]
  where
    go [] = return False
    go ((cmd, args) : rest) = do
      r <- try (readProcessWithExitCode cmd args (T.unpack txt))
             :: IO (Either IOException (ExitCode, String, String))
      case r of
        Right (ExitSuccess, _, _) -> return True
        _ -> go rest

-- | Save the clipboard image and return its path, or 'Nothing'.
saveClipboardImage :: IO (Maybe FilePath)
saveClipboardImage = do
  home <- getHomeDirectory
  let dir = home </> ".trha" </> "paste"
  createDirectoryIfMissing True dir
  t <- getPOSIXTime
  let out = dir </> ("paste-" <> show (round (t * 1000) :: Int) <> ".png")
      q = "'" <> out <> "'"
      candidates =
        [ "wl-paste -t image/png > " <> q
        , "xclip -selection clipboard -t image/png -o > " <> q
        , "pngpaste " <> q
        ]
  ok <- tryAll candidates
  if not ok then pure Nothing else do
    sz <- getFileSize out `catch` \(_ :: IOException) -> pure 0
    pure (if sz > 0 then Just out else Nothing)
  where
    tryAll [] = pure False
    tryAll (c : cs) = do
      r <- try (readProcessWithExitCode "sh" ["-c", c] "")
             :: IO (Either IOException (ExitCode, String, String))
      case r of
        Right (ExitSuccess, _, _) -> pure True
        _ -> tryAll cs
