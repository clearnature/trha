{-# LANGUAGE OverloadedStrings #-}

-- | Pure status-footer segments for the TUI.  Kept free of brick so the
-- layout text is unit-testable; "UI.Brick" renders the segments joined by
-- separators.
module UI.Render.Footer
  ( footerSegments
  , footerHints
    -- * Configurable metrics footer
  , metricKeys
  , defaultMetrics
  , parseMetrics
  , FooterLive(..)
  , footerMetrics
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import UI.I18n (Lang(..), tr)
import Core.Types (Usage(..))

-- | Key hints shown at the end of the footer.
footerHints :: Text
footerHints = "PgUp/PgDn scroll · g/G top/bottom · Ctrl+O expand tool output · Ctrl+Q quit"

-- | Status line segments, in display order: model, session, status,
-- optional last-run usage, then the fixed key hints.
footerSegments :: Text -> Maybe String -> Text -> Maybe Int -> [Text]
footerSegments model mSession status mUsage =
  [ "Model: " <> model
  , "Session: " <> maybe "none" T.pack mSession
  , status
  ]
    <> maybe [] (\n -> ["last: " <> T.pack (show n) <> " tokens"]) mUsage
    <> [footerHints]

-- Configurable status-line metrics -------------------------------------------------

-- | Keys this build can display in the footer (a subset of the reference
-- CLI statusline catalogue: model / git / workspace / context / tokens /
-- session).
metricKeys :: [Text]
metricKeys = ["model", "git", "workspace", "context", "tokens", "session", "usage"]

-- | Keys shown by default (order matters).
defaultMetrics :: Text
defaultMetrics = "model,usage,context,session"

-- | Parse a metrics configuration: keep supported keys, in order, unique.
parseMetrics :: Text -> [Text]
parseMetrics raw = dedup [ k | k <- T.splitOn "," raw', k `elem` metricKeys ]
  where
    raw' = T.toLower (T.strip raw)
    dedup = foldl (\acc k -> if k `elem` acc then acc else acc ++ [k]) []

-- | Live, cheaply-available values for the footer metrics.
data FooterLive = FooterLive
  { flModel   :: Text
  , flSession :: Maybe Text
  , flStatus  :: Text
  , flUsage   :: Maybe Int   -- ^ last reply tokens
  , flChars   :: Int         -- ^ message-area characters (context)
  , flDetail  :: Maybe Usage -- ^ in/out/total of the last turn (real echo)
  , flCtxSize :: Maybe Int   -- ^ model context size (occupancy %)
  } deriving (Show, Eq)

-- | Render the configured metrics as footer segments (localised labels).
-- Static lookups (workspace path, git branch) arrive as name/value pairs.
footerMetrics :: Lang -> [Text] -> FooterLive -> [(Text, Text)] -> [Text]
footerMetrics lang order live statics = map render order
  where
    render "model"     = tr lang "Model: " <> flModel live
    render "git"       = tr lang "Git branch: " <> lookupVal "git"
    render "workspace" = tr lang "Workspace: " <> lookupVal "workspace"
    render "context"   = tr lang "Context: " <> T.pack (show (flChars live)) <> tr lang " chars"
    render "tokens"    = tr lang "Tokens: " <> maybe "—" (T.pack . show) (flUsage live)
    render "session"   = tr lang "Session: " <> fromMaybe (tr lang "none") (flSession live)
    render "usage"     = case flDetail live of
      Nothing -> ""
      Just u  ->
        tr lang "in" <> " " <> T.pack (show (usagePromptTokens u)) <> tr lang " · "
          <> tr lang "out" <> " " <> T.pack (show (usageCompletionTokens u)) <> tr lang " · "
          <> tr lang "total" <> " " <> T.pack (show (usageTotalTokens u))
          <> maybe "" occupancy (occupancyPct u)
    occupancy q = tr lang " · ctx " <> T.pack (show q) <> "%"
    occupancyPct u =
      let cin = usagePromptTokens u
      in case flCtxSize live of
           Just cs | cs > 0 -> Just (round (fromIntegral cin / fromIntegral cs * 100 :: Double))
           _                -> Nothing
    lookupVal k = fromMaybe "—" (lookup k statics)
