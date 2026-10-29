{-# LANGUAGE OverloadedStrings #-}

-- | Pure status-footer segments for the TUI.  Kept free of brick so the
-- layout text is unit-testable; "UI.Brick" renders the segments joined by
-- separators.
module UI.Render.Footer
  ( footerSegments
  , footerHints
  , branchFromHead
    -- * Configurable metrics footer
  , metricKeys
  , defaultMetrics
  , parseMetrics
  , FooterLive(..)
  , footerMetrics
    -- * Status-row fitting
  , statusFitsOneRow
  , statusRowGap
  , wrapStatusLine
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showFFloat)
import UI.I18n (Lang(..), tr)
import UI.TextWidth (dropCells, graphemes, takeCells, textWidth)
import Core.Types (Usage(..))

-- | Key hints shown at the end of the footer.
footerHints :: Text
footerHints =
  "Shift+Tab read-only/ask/auto/YOLO/plan · Ctrl+Y YOLO · Ctrl+O expand tool output · Ctrl+Q quit · Ctrl+Alt+Q stop services · Ctrl+C twice"

-- | Branch name from @.git/HEAD@ content: @ref: refs/heads/main@ → @Just "main"@.
-- A bare SHA (detached HEAD) has no branch, so it returns 'Nothing'.
branchFromHead :: Text -> Maybe Text
branchFromHead hd = do
  ref <- T.stripPrefix "ref: " (T.strip hd)
  let name = last (T.splitOn "/" (T.strip ref))
  if T.null name then Nothing else Just name

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
-- session, plus Reasonix's mode / cache / ctx / compact).
metricKeys :: [Text]
metricKeys =
  [ "model", "git", "workspace", "context", "tokens", "session", "usage"
  , "mode", "cache", "ctx", "compact", "tps", "balance", "cost", "peak"
  , "out", "cacheTokens", "sessTokens", "costTurn", "costSession"
  ]

-- | Keys shown by default (order matters).
defaultMetrics :: Text
defaultMetrics = "model,mode,cache,ctx,compact,session"

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
  , flMode    :: Maybe Text  -- ^ permission posture label (Shift+Tab)
  , flCacheNow :: Maybe (Int, Int) -- ^ last turn (hit, miss)
  , flCacheSum :: Maybe (Int, Int) -- ^ session total (hit, miss)
  , flCtxUsed :: Maybe Int         -- ^ last prompt tokens (context used)
  , flCompactLeft :: Maybe Int     -- ^ compaction headroom percent
  , flTps :: Maybe Double          -- ^ completion tokens per second (last turn)
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
    render "mode"      = tr lang "Mode: " <> fromMaybe (tr lang "unknown") (flMode live)
    render "cache"     = case (rate (flCacheNow live), rate (flCacheSum live)) of
      (Just now, Just avg) -> tr lang "cache " <> tr lang "turn hit " <> now
                                <> tr lang " · session " <> avg
      (Just now, Nothing)  -> tr lang "cache " <> tr lang "turn hit " <> now
      (Nothing, Just avg)  -> tr lang "cache " <> tr lang "session " <> avg
      _                    -> ""
    render "ctx"       = case flCtxUsed live of
      Just used -> tr lang "context " <> shortTokens used
                     <> maybe "" (\p -> " (" <> T.pack (show p) <> "%)") flCtxPct
      Nothing   -> ""
    render "compact"   = case flCompactLeft live of
      Just left -> tr lang "compact " <> T.pack (show left) <> "%"
      Nothing   -> ""
    render "tps"       = case flTps live of
      Just t  -> tr lang "tps " <> T.pack (showFFloat (Just 1) t "")
      Nothing -> ""
    occupancy q = tr lang " · ctx " <> T.pack (show q) <> "%"
    occupancyPct u =
      let cin = usagePromptTokens u
      in case flCtxSize live of
           Just cs | cs > 0 -> Just (round (fromIntegral cin / fromIntegral cs * 100 :: Double))
           _                -> Nothing
    -- Context occupancy and compaction headroom share the same denominator.
    flCtxPct = case (flCtxUsed live, flCtxSize live) of
      (Just used, Just cs) | cs > 0 ->
        Just (round (fromIntegral used / fromIntegral cs * 100 :: Double))
      _ -> Nothing
    lookupVal k = fromMaybe "—" (lookup k statics)

-- | Minimum blank cells between the git summary and the metrics when both
-- share the second status row.
statusRowGap :: Int
statusRowGap = 2

-- | Whether the second status row can hold the git summary on the left and
-- the metrics on the right in @avail@ cells.
--
-- The row used to be an unconditional @hBox [git, padLeft Max metrics]@:
-- once the git summary grew (@dir\@branch +N -M ?K@) and the metrics grew
-- (cache / ctx / compact / balance / cost / peak), the right end of the
-- metrics was silently clipped on a 120-column terminal with no way to see
-- it.  When it does not fit, the caller gives the metrics their own row.
statusFitsOneRow :: Int -> Text -> Text -> Bool
statusFitsOneRow avail git stats
  | T.null git || T.null stats = True
  | otherwise = textWidth git + statusRowGap + textWidth stats <= avail

-- | Separator between status segments, and the preferred wrap point.
statusSegmentSep :: Text
statusSegmentSep = "  "

-- | Greedy packing of segments into rows of at most @limit@ cells.
packStatusSegments :: Int -> [Text] -> [Text]
packStatusSegments limit = go [] 0
  where
    go acc _ [] = [T.intercalate statusSegmentSep (reverse acc) | not (null acc)]
    go [] _ (s:ss) = go [s] (textWidth s) ss
    go acc w (s:ss)
      | w + textWidth statusSegmentSep + textWidth s <= limit =
          go (s : acc) (w + textWidth statusSegmentSep + textWidth s) ss
      | otherwise = T.intercalate statusSegmentSep (reverse acc) : go [s] (textWidth s) ss

-- | Wrap a status row to @limit@ cells by **display width**.
--
-- Brick's 'strWrap' measures with @Text.Wrap@, which counts code points: a
-- Chinese status row that occupies 98 cells measured as 98 characters but
-- was wrapped against a 90-cell budget only after 90 characters, so it kept
-- overflowing (verified with a headless render).  This wraps on
-- grapheme-cluster cell widths and prefers the two-space segment boundary,
-- so a long row is split into rows that actually fit.
wrapStatusLine :: Int -> Text -> [Text]
wrapStatusLine limit t
  | T.null (T.strip t) = []
  | limit <= 0         = [t]
  | otherwise          = concatMap hardSplit (packStatusSegments limit (T.splitOn statusSegmentSep t))
  where
    hardSplit row
      | T.null row             = []
      | textWidth row <= limit = [row]
      | otherwise = case graphemes row of
          [] -> []
          (g : gs) ->
            let a = takeCells limit row
            in if T.null a
                 -- One cluster is wider than the whole budget (a CJK glyph
                 -- with limit 1): emit it alone so wrapping still progresses.
                 then g : hardSplit (T.concat gs)
                 else a : hardSplit (dropCells limit row)

-- | Cache-hit percentage as rendered text ("99.93%"), or Nothing when the
-- provider reported no cache accounting (never fake a 0.00%).
rate :: Maybe (Int, Int) -> Maybe Text
rate Nothing = Nothing
rate (Just (hit, miss))
  | hit + miss <= 0 = Nothing
  | otherwise =
      Just $ T.pack (showFFloat (Just 2) (fromIntegral hit * 100 / fromIntegral (hit + miss)) "") <> "%"

-- | Compact token counts: 450.1K, 1.2M, 987.
shortTokens :: Int -> Text
shortTokens n
  | n >= 1000000 = one "M" 1000000
  | n >= 1000    = one "K" 1000
  | otherwise    = T.pack (show n)
  where
    one suffix unit =
      T.pack (showFFloat (Just 1) (fromIntegral n / fromIntegral unit :: Double) "") <> suffix
