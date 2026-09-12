{-# LANGUAGE OverloadedStrings #-}

module UI.Render.ToolCard
  ( -- * Status
    ToolStatus(..)
    -- * Layout
  , toolTitle
  , toolArgLines
  , toolCardLines
  , toolStatusLine
  , toolCardWithStatus
    -- * Limits
  , cardWidth
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Execution status of a tool invocation (extended in later phases with
-- exit codes / duration once the kernel reports them).
data ToolStatus
  = ToolRunning
  | ToolSucceeded
  | ToolFailed Text
  deriving (Show, Eq)

-- | Maximum display width of a card line (in characters).
cardWidth :: Int
cardWidth = 72

-- | Card title line, e.g. @[tool] read_file@.
toolTitle :: Text -> Text
toolTitle name = "[tool] " <> name

-- | One line per argument, indented by two spaces and truncated to
-- 'cardWidth' total characters.
toolArgLines :: [Text] -> [Text]
toolArgLines args = ["  " <> truncateTo (cardWidth - 2) a | a <- args]
  where
    truncateTo n t
      | T.length t <= n = t
      | otherwise       = T.take (n - 1) t <> "…"

-- | Full card: title line followed by argument lines.
toolCardLines :: Text -> [Text] -> [Text]
toolCardLines name args = toolTitle name : toolArgLines args

-- | Status footer line for a tool card (Phase 2 S2).
toolStatusLine :: ToolStatus -> Maybe Int -> Text
toolStatusLine ToolRunning _        = "  running…"
toolStatusLine ToolSucceeded (Just ms) = "  ✓ " <> T.pack (show ms) <> "ms"
toolStatusLine ToolSucceeded Nothing   = "  ✓ done"
toolStatusLine (ToolFailed err) _  = "  ✗ " <> err

-- | Full card including the status footer line.
toolCardWithStatus :: Text -> [Text] -> ToolStatus -> Maybe Int -> [Text]
toolCardWithStatus name args status dur =
  toolCardLines name args <> [toolStatusLine status dur]
