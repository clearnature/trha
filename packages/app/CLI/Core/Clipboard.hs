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
  ) where

import Control.Exception (IOException, catch, try)
import System.Directory (createDirectoryIfMissing, getFileSize, getHomeDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import Data.Time.Clock.POSIX (getPOSIXTime)

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
