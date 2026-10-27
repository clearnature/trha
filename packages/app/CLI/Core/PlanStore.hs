{-# LANGUAGE OverloadedStrings #-}

-- | Plan snapshots under @~/.trha/plans/@.
--
-- The kernel owns the live plan, but a plan that only exists in memory
-- disappears with the session.  Every plan view the shell receives is
-- mirrored to @plans/<session-id>.md@ (latest wins) so a user can read what
-- was agreed after the fact — the same role @~/.claude/plans@ plays.
module Core.PlanStore
  ( planDir
  , savePlanSnapshot
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

import Config.Settings (getConfigDir)
import Core.Types (PlanView, renderPlanBrief)

-- | @~/.trha/plans@.
planDir :: IO FilePath
planDir = (</> "plans") <$> getConfigDir

-- | Write the live plan to @plans/<session>.md@; returns the path written.
--
-- Session ids arrive from the kernel and may contain characters a file name
-- cannot carry, so they are folded to @_@ (the plan body still names the id).
savePlanSnapshot :: Text -> PlanView -> IO FilePath
savePlanSnapshot sid pv = do
  dir <- planDir
  createDirectoryIfMissing True dir
  setFileMode dir 0o700
  let name = map sanitize (T.unpack (T.strip sid))
      file = if null name then "current" else name
      path = dir </> (file <> ".md")
  TIO.writeFile path (renderPlanBrief pv)
  pure path
  where
    sanitize c
      | c `elem` ("/\\:*?\"<>|" :: String) = '_'
      | c == ' ' = '_'
      | otherwise = c
