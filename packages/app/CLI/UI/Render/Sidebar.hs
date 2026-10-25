{-# LANGUAGE OverloadedStrings #-}

-- | Sidebar content (M4-1): pure line model for the three sections —
-- Context (usage / context occupancy), TODO (team tasks) and Session
-- (id / title / model).  The widget layer turns these lines into cells;
-- keeping them pure makes the section order, empty states and truncation
-- testable without brick.
module UI.Render.Sidebar
  ( SidebarData(..)
  , SidebarLine(..)
  , emptySidebarData
  , sidebarLines
  , truncateTo
  ) where

import Core.Types (TodoItem(..), TodoStatus(..), Usage(..))
import Data.Text (Text)
import qualified Data.Text as T

-- | Everything the sidebar shows.
data SidebarData = SidebarData
  { sdUsage     :: Maybe Usage
  , sdCtxSize   :: Maybe Int
  , sdTodos     :: [TodoItem]
  , sdSessionId :: Maybe Text
  , sdTitle     :: Maybe Text
  , sdModel     :: Text
  } deriving (Show, Eq)

-- | One renderable line: text plus the theme attribute name it uses.
data SidebarLine = SidebarLine
  { slAttr :: String
  , slText :: Text
  } deriving (Show, Eq)

-- | All-empty sidebar (no session, no usage, no tasks).
emptySidebarData :: SidebarData
emptySidebarData = SidebarData Nothing Nothing [] Nothing Nothing ""

-- | Lines for a content width of @width@ columns.  Each line is truncated
-- with an ellipsis so the widget cannot overflow its column.
sidebarLines :: Int -> SidebarData -> [SidebarLine]
sidebarLines width d = concat
  [ [header "Context"]
  , contextLines
  , [header "TODO"]
  , todoLines
  , [header "Session"]
  , sessionLines
  ]
  where
    w = max 1 width

    header = SidebarLine "title" . cut
    body   = SidebarLine "tool" . cut
    muted  = SidebarLine "timestamp" . cut

    cut = truncateTo w

    contextLines = case sdUsage d of
      Nothing -> [muted "no usage yet"]
      Just u ->
        [ body ("in " <> showInt (usagePromptTokens u)
                <> " · out " <> showInt (usageCompletionTokens u))
        , body ("total " <> showInt (usageTotalTokens u) <> occupancy u)
        ]
    occupancy u = case sdCtxSize d of
      Just cs | cs > 0 ->
        let pct = round (fromIntegral (usagePromptTokens u)
                         / fromIntegral cs * 100 :: Double) :: Int
        in " · ctx " <> showInt pct <> "%"
      _ -> ""

    todoLines = case sdTodos d of
      [] -> [muted "No tasks"]
      ts -> [ body (glyph (todoStatus t) <> " " <> todoSubject t) | t <- ts ]

    glyph st = case st of
      TodoPending    -> "○"
      TodoInProgress -> "◐"
      TodoDone       -> "●"

    sessionLines =
      body (maybe "no session" ("id " <>) (sdSessionId d))
        : maybe [] (\t -> [muted ("title " <> t)]) (sdTitle d)
        ++ [ body ("model " <> sdModel d) | not (T.null (sdModel d)) ]

    showInt :: Int -> Text
    showInt = T.pack . show

-- | Truncate to at most @width@ characters, marking a cut with an
-- ellipsis.  Widths are counted in characters (the sidebar shows ASCII
-- ids and model names; wide text may still overflow slightly).
truncateTo :: Int -> Text -> Text
truncateTo width t
  | T.length t <= width = t
  | width <= 1          = T.take (max 0 width) t
  | otherwise           = T.take (width - 1) t <> "…"
