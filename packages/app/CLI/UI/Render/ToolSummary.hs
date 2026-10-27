{-# LANGUAGE OverloadedStrings #-}

-- | Per-tool card shape (MiMo parity).
--
-- MiMo renders one component per tool family (`routes/session/index.tsx`
-- matches 17 tool names) instead of dumping a generic name+args card.  trha's
-- tool set is different but the families are the same: shell, read, search,
-- edit, write, network, agent, ask, skill, present, plan.  This module maps a
-- tool name to its family and produces the card's headline/detail lines; the
-- existing generic card stays the fallback.
module UI.Render.ToolSummary
  ( ToolKind(..)
  , toolKindOf
  , argOf
  , toolHeadline
  , toolDetailLines
  , presentCard
  , outputStats
  ) where

import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import UI.Render.ToolCard

-- | Tool family, i.e. which card shape to use.
data ToolKind
  = KShell | KRead | KSearch | KEdit | KWrite | KNet
  | KAgent | KAsk | KSkill | KPresent | KPlan | KGeneric
  deriving (Show, Eq)

-- | Classify a tool name (aliases included).
toolKindOf :: Text -> ToolKind
toolKindOf raw = case T.toLower raw of
  "bash" -> KShell
  "shell" -> KShell
  "run_shell" -> KShell
  "exec_command" -> KShell
  "pwsh" -> KShell
  "read" -> KRead
  "read_file" -> KRead
  "read_image" -> KRead
  "view_image" -> KRead
  "glob" -> KSearch
  "grep" -> KSearch
  "codesearch" -> KSearch
  "edit" -> KEdit
  "apply_patch" -> KEdit
  "unified_edit" -> KEdit
  "str_replace_editor" -> KEdit
  "write" -> KWrite
  "write_file" -> KWrite
  "append_file" -> KWrite
  "web_fetch" -> KNet
  "webfetch" -> KNet
  "web_search" -> KNet
  "websearch" -> KNet
  "subagent" -> KAgent
  "workflow" -> KAgent
  "task" -> KAgent
  "actor" -> KAgent
  "spawn_teammate" -> KAgent
  "wait_agent" -> KAgent
  "ask_user_question" -> KAsk
  "question" -> KAsk
  "skill" -> KSkill
  "present" -> KPresent
  "exit_plan_mode" -> KPlan
  other
    | "team_task_" `T.isPrefixOf` other -> KAgent
    | otherwise -> KGeneric

-- | Look up an argument by key.  The scheduler sends @["key=value", …]@
-- (see its @parseToolArgs@); a raw JSON fallback string simply misses.
argOf :: Text -> [Text] -> Maybe Text
argOf key args = listToMaybe (mapMaybe (T.stripPrefix (key <> "=")) args)

-- | Collapsed one-liner: tool name, its salient argument, and status.
toolHeadline :: ToolCard -> Text
toolHeadline card =
  truncateTo (cardWidth - 2) $
    "[tool] " <> T.pack (tcName card)
      <> statusSuffix (tcStatus card) (tcDur card)
      <> maybe "" (" " <>) (salient kind card)
  where
    kind = toolKindOf (T.pack (tcName card))

-- | Expanded detail lines that are not the raw output preview (the caller
-- renders the output / diff itself).
toolDetailLines :: ToolCard -> [Text]
toolDetailLines card = case kind of
  KShell -> maybe [] (\c -> ["  $ " <> oneLine c]) (argOf "command" args)
  KEdit -> case argOf "path" args of
    Just p -> ["  " <> p <> diffSuffix]
    Nothing -> toolArgLines args
  KWrite -> case argOf "path" args of
    Just p -> ["  " <> p <> writeSuffix]
    Nothing -> toolArgLines args
  KAsk -> questionLines
  KPresent -> case presentCard card of
    Just (title, body) -> ["  " <> title] <> ["  │ " <> l | l <- T.lines body]
    Nothing -> toolArgLines args
  KSkill -> maybe [] (\n -> ["  skill: " <> n]) (argOf "name" args)
  KAgent -> maybe [] (\t -> ["  task: " <> oneLine t]) (agentTask card)
  _ -> toolArgLines args
  where
    args = tcArgs card
    kind = toolKindOf (T.pack (tcName card))
    diffSuffix =
      let (adds, dels) = outputStats (tcOutput card)
      in if adds + dels == 0 then "" else "  +" <> tshow adds <> "/-" <> tshow dels
    writeSuffix =
      let n = length (tcOutput card)
      in if n == 0 then "" else "  " <> tshow n <> " lines"
    questionLines =
      [ "  " <> oneLine q | Just q <- [argOf "question" args] ]
        <> [ "  · " <> oneLine o | Just os <- [argOf "options" args], o <- splitOptions os ]
    splitOptions = filter (not . T.null) . map T.strip . T.splitOn ","

-- | A @present@ tool call is a card: title plus body.
presentCard :: ToolCard -> Maybe (Text, Text)
presentCard card
  | toolKindOf (T.pack (tcName card)) /= KPresent = Nothing
  | otherwise =
      let args = tcArgs card
          title = fromMaybe "present" (argOf "title" args)
          body = fromMaybe (T.unlines (tcOutput card)) (argOf "body" args)
      in Just (title, body)

-- | Diff line counts: (added, removed).  Hunk headers and file headers are
-- not counted.
outputStats :: [Text] -> (Int, Int)
outputStats ls = (adds, dels)
  where
    adds = length [ () | l <- ls, "+" `T.isPrefixOf` l, not ("+++" `T.isPrefixOf` l) ]
    dels = length [ () | l <- ls, "-" `T.isPrefixOf` l, not ("---" `T.isPrefixOf` l) ]

-- | The argument that best identifies a call in one line.
salient :: ToolKind -> ToolCard -> Maybe Text
salient kind card = case kind of
  KShell -> argOf "command" args
  KRead -> argOf "path" args
  KSearch -> firstOf ["pattern", "query", "glob"]
  KEdit -> argOf "path" args
  KWrite -> argOf "path" args
  KNet -> firstOf ["url", "query"]
  KAgent -> agentTask card
  KAsk -> argOf "question" args
  KSkill -> argOf "name" args
  KPresent -> argOf "title" args
  KPlan -> argOf "action" args
  KGeneric -> listToMaybe args
  where
    args = tcArgs card
    firstOf keys = listToMaybe (mapMaybe (`argOf` args) keys)

agentTask :: ToolCard -> Maybe Text
agentTask card = listToMaybe (mapMaybe (`argOf` tcArgs card) ["task", "description", "prompt"])

oneLine :: Text -> Text
oneLine = T.unwords . T.words

tshow :: Int -> Text
tshow = T.pack . show

truncateTo :: Int -> Text -> Text
truncateTo n t
  | T.length t <= n = t
  | otherwise       = T.take (n - 1) t <> "…"
