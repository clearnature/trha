{-# LANGUAGE OverloadedStrings #-}

-- | Sidebar content (M4-1): a pure line model built from pluggable sections.
--
-- Sections mirror MiMo's @feature-plugins/sidebar/*.tsx@: each one owns its
-- title and lines, and 'sidebarSections' is the registry.  Adding a section
-- (LSP, MCP, a future plugin) is one entry there, not an edit of a big
-- @sidebarLines@ case.  Keeping this pure makes section order, empty states
-- and truncation testable without brick.
module UI.Render.Sidebar
  ( SidebarData(..)
  , SidebarLine(..)
  , SidebarSection(..)
  , sidebarSections
  , emptySidebarData
  , sidebarLines
  , sidebarHint
  , agentTreeLines
  , truncateTo
  ) where

import Core.Types (AgentEntry(..), TodoItem(..), TodoStatus(..), Usage(..))
import Data.Text (Text)
import qualified Data.Text as T
import UI.I18n (Lang, tr)

-- | Everything the sidebar shows.
data SidebarData = SidebarData
  { sdUsage     :: Maybe Usage
  , sdCtxSize   :: Maybe Int
  , sdTodos     :: [TodoItem]
  , sdSessionId :: Maybe Text
  , sdTitle     :: Maybe Text
  , sdModel     :: Text
  , sdCwd       :: Maybe Text      -- ^ working directory
  , sdFiles     :: [Text]          -- ^ a few workspace files
  , sdGoal      :: Maybe Text      -- ^ session goal objective
  , sdInstructions :: [Text]       -- ^ AGENTS.md / REASONIX.md present
  , sdAgents    :: [AgentEntry]    -- ^ session tree (subagents)
  , sdLsp       :: [Text]          -- ^ LSP status lines
  , sdMcp       :: [Text]          -- ^ MCP status lines
  } deriving (Show, Eq)

-- | One renderable line: text plus the theme attribute name it uses.
data SidebarLine = SidebarLine
  { slAttr :: String
  , slText :: Text
  } deriving (Show, Eq)

-- | One sidebar section (MiMo's sidebar plugin unit).
data SidebarSection = SidebarSection
  { secId    :: Text
  , secTitle :: Text
  , secLines :: Int -> SidebarData -> [SidebarLine]
  }

-- | The registry.  Order is display order; every section is independent.
sidebarSections :: [SidebarSection]
sidebarSections =
  [ SidebarSection "context" "Context" contextLines
  , SidebarSection "cwd" "CWD" cwdLines
  , SidebarSection "files" "Files" fileLines
  , SidebarSection "goal" "Goal" goalLines
  , SidebarSection "instructions" "Instructions" instructionLines
  , SidebarSection "todo" "TODO" todoLines
  , SidebarSection "agents" "Agents" agentLines
  , SidebarSection "lsp" "LSP" lspLines
  , SidebarSection "mcp" "MCP" mcpLines
  , SidebarSection "session" "Session" sessionLines
  ]

-- | All-empty sidebar (no session, no usage, no tasks).
emptySidebarData :: SidebarData
emptySidebarData =
  SidebarData Nothing Nothing [] Nothing Nothing "" Nothing [] Nothing [] [] [] []

-- | Lines for a content width of @width@ columns.  Each line is truncated
-- with an ellipsis so the widget cannot overflow its column.
sidebarLines :: Int -> SidebarData -> [SidebarLine]
sidebarLines width d = concat
  [ SidebarLine "title" (truncateTo width (secTitle s)) : secLines s width d
  | s <- sidebarSections
  ]

-- | Key hint shown at the bottom of the sidebar, on one line: toggling the
-- sidebar and leaving the TUI (the two shortcuts a first-time user needs).
-- The caller truncates it to the panel width.
sidebarHint :: Lang -> Text
sidebarHint lang = tr lang "Ctrl+B sidebar toggle    Ctrl+Q quit    Ctrl+C twice"

--------------------------------------------------------------------------------
-- Sections (each owns its own empty state)
--------------------------------------------------------------------------------

-- | Local helpers: every section truncates to the width it was handed.
bodyAt, mutedAt :: Int -> Text -> SidebarLine
bodyAt w t  = SidebarLine "tool" (truncateTo w t)
mutedAt w t = SidebarLine "timestamp" (truncateTo w t)

contextLines :: Int -> SidebarData -> [SidebarLine]
contextLines w d = case sdUsage d of
  Nothing -> [mutedAt w "no usage yet"]
  Just u ->
    [ bodyAt w ("in " <> showInt (usagePromptTokens u)
                <> " · out " <> showInt (usageCompletionTokens u))
    , bodyAt w ("total " <> showInt (usageTotalTokens u) <> occupancy u)
    ]
  where
    occupancy u = case sdCtxSize d of
      Just cs | cs > 0 ->
        let pct = round (fromIntegral (usagePromptTokens u)
                         / fromIntegral cs * 100 :: Double) :: Int
        in " · ctx " <> showInt pct <> "%"
      _ -> ""

cwdLines :: Int -> SidebarData -> [SidebarLine]
cwdLines w d = case sdCwd d of
  Nothing -> [mutedAt w "unknown"]
  Just c  -> [bodyAt w c]

fileLines :: Int -> SidebarData -> [SidebarLine]
fileLines w d = case take 5 (sdFiles d) of
  [] -> [mutedAt w "no files"]
  fs -> [bodyAt w f | f <- fs]

goalLines :: Int -> SidebarData -> [SidebarLine]
goalLines w d = case sdGoal d of
  Nothing -> [mutedAt w "no goal"]
  Just g  -> [bodyAt w g]

instructionLines :: Int -> SidebarData -> [SidebarLine]
instructionLines w d = case sdInstructions d of
  [] -> [mutedAt w "none detected"]
  is -> [bodyAt w i | i <- is]

todoLines :: Int -> SidebarData -> [SidebarLine]
todoLines w d = case sdTodos d of
  [] -> [mutedAt w "No tasks"]
  ts -> [bodyAt w (glyph (todoStatus t) <> " " <> todoSubject t) | t <- ts]
  where
    glyph st = case st of
      TodoPending    -> "○"
      TodoInProgress -> "◐"
      TodoDone       -> "●"

agentLines :: Int -> SidebarData -> [SidebarLine]
agentLines w d = case sdAgents d of
  [] -> [mutedAt w "no agents"]
  as -> [bodyAt w l | l <- agentTreeLines (sdSessionId d) as]

lspLines :: Int -> SidebarData -> [SidebarLine]
lspLines w d = case sdLsp d of
  [] -> [mutedAt w "off"]
  ls -> [bodyAt w l | l <- ls]

mcpLines :: Int -> SidebarData -> [SidebarLine]
mcpLines w d = case sdMcp d of
  [] -> [mutedAt w "none configured"]
  ms -> [bodyAt w m | m <- ms]

sessionLines :: Int -> SidebarData -> [SidebarLine]
sessionLines w d =
  bodyAt w (maybe "no session" ("id " <>) (sdSessionId d))
    : maybe [] (\t -> [mutedAt w ("title " <> t)]) (sdTitle d)
    ++ [ bodyAt w ("model " <> sdModel d) | not (T.null (sdModel d)) ]

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

-- | Indented agent tree: roots first, children under their parent, the
-- current session marked with ●.  Capped so the sidebar cannot grow without
-- bound.
agentTreeLines :: Maybe Text -> [AgentEntry] -> [Text]
agentTreeLines cur entries = take 8 (concatMap (walk 0) roots)
  where
    ids = map aeId entries
    roots = [ e | e <- entries, maybe True (`notElem` ids) (aeParent e) ]
    childrenOf pid = [ e | e <- entries, aeParent e == Just pid ]
    walk depth e =
      (T.replicate depth "  " <> (if Just (aeId e) == cur then "● " else "· ") <> aeId e)
        : concatMap (walk (depth + 1)) (childrenOf (aeId e))
