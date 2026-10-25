{-# LANGUAGE OverloadedStrings #-}

module UI.Render.ToolCard
  ( -- * Status
    ToolStatus(..)
    -- * Card data
  , ToolCard(..)
    -- * Fold states
  , ToolFold(..)
  , toggleFold
    -- * Layout
  , toolTitle
  , toolArgLines
  , toolCardLines
  , toolStatusLine
  , toolCardWithStatus
  , toolCardView
  , toolCardCollapsed
  , toolCardExpanded
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

-- | A tool invocation as one renderable card: identity, optional execution
-- outcome (absent while running or unreported), and the kernel's tail
-- output preview.
data ToolCard = ToolCard
  { tcName   :: String
  , tcArgs   :: [Text]
  , tcStatus :: Maybe ToolStatus
  , tcDur    :: Maybe Int
  , tcOutput :: [Text]
  } deriving (Show, Eq)

-- | Fold state of a card: collapsed shows one summary line, expanded
-- shows arguments and output.
data ToolFold = FoldCollapsed | FoldExpanded
  deriving (Show, Eq)

-- | Flip a fold state.
toggleFold :: ToolFold -> ToolFold
toggleFold FoldCollapsed = FoldExpanded
toggleFold FoldExpanded  = FoldCollapsed

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

-- | Inline status tag for the collapsed one-liner.
statusSuffix :: Maybe ToolStatus -> Maybe Int -> Text
statusSuffix mst mdur = case mst of
  Nothing              -> " (running…)"
  Just ToolRunning     -> " (running…)"
  Just ToolSucceeded   -> " ✓" <> maybe "" (\ms -> " " <> T.pack (show ms) <> "ms") mdur
  Just (ToolFailed _)  -> " ✗"

-- | Collapsed card: a single summary line (first two arguments inline).
toolCardCollapsed :: ToolCard -> [Text]
toolCardCollapsed card = [truncateTo (cardWidth - 2) title]
  where
    title = toolTitle (T.pack (tcName card))
              <> statusSuffix (tcStatus card) (tcDur card)
              <> maybe "" (" " <>) (argSummary (tcArgs card))
    argSummary [] = Nothing
    argSummary as = Just (T.unwords (take 2 (map (T.replace "\n" " ") as)))
    truncateTo n t
      | T.length t <= n = t
      | otherwise       = T.take (n - 1) t <> "…"

-- | Expanded card: title, argument lines, kernel output preview (each
-- line width-truncated and bar-prefixed), status footer.
toolCardExpanded :: ToolCard -> [Text]
toolCardExpanded card =
  toolCardLines (T.pack (tcName card)) (tcArgs card)
    <> [ ("  │ " <> truncateTo (cardWidth - 4) l) | l <- tcOutput card ]
    <> [ toolStatusLine st (tcDur card) | Just st <- [tcStatus card] ]
  where
    truncateTo n t
      | T.length t <= n = t
      | otherwise       = T.take (n - 1) t <> "…"

-- | Render a card in its current fold state.
toolCardView :: ToolFold -> ToolCard -> [Text]
toolCardView FoldCollapsed = toolCardCollapsed
toolCardView FoldExpanded  = toolCardExpanded
