-- | The standard @~/.trha@ layout.
--
-- The reference agent CLIs all ship a recognisable home directory
-- (@.claude@, @.codex@, @.codebuddy@, @.dsh@, @.reasonix@, @.qwen@): one
-- place per kind of data — sessions, skills, plans, logs, cache — instead of
-- a handful of loose files.  trha's data directory had grown only what the
-- current code paths happened to write, so it looked sparse next to them.
--
-- This module owns the list and creates it on first run (0700, like the
-- directory itself).  Directories are created up front even when a feature
-- does not write to them yet: dropping a @SKILL.md@ into @skills/@ or a
-- command file into @commands/@ should just work, without the user having to
-- guess and create the parent first.
module Config.Home
  ( -- * Layout
    homeLayout
    -- * Initialisation
  , initHomeDirs
  ) where

import Control.Monad (forM)
import Data.Maybe (catMaybes)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist)
import System.FilePath ((</>))
import Infrastructure.Platform.FileMode (setFileMode)

-- | Standard subdirectories of @~/.trha@, in display order.
--
-- Loose files stay where they are (@settings.yaml@, @providers.json@,
-- @history@, …); only the structure below is new.
homeLayout :: [FilePath]
homeLayout =
  [ -- conversation data
    "sessions"          -- <session-id>/transcript.jsonl
  , "scheduler-state"   -- the scheduler's persisted session state
    -- content the user writes
  , "skills"            -- <name>/SKILL.md, scanned by /skills
  , "agents"            -- sub-agent definitions
  , "commands"          -- user slash commands
  , "rules"             -- global rules (project rules live in AGENTS.md)
  , "memories"          -- long-term notes (/memory)
    -- generated / operational
  , "plans"             -- approved plan snapshots
  , "projects"          -- per-project state
  , "logs"              -- run logs
  , "cache"             -- regenerable caches
  , "state"             -- small state files (frecency, models, currency, stash)
  , "backups"           -- settings / provider backups
  , "file-history"      -- edit snapshots
    -- media
  , "paste"             -- clipboard images
  , "voice"             -- voice notes
  , "exports"           -- /export output
  ]

-- | Create every directory in 'homeLayout' under @root@ (0700) and return the
-- ones that did not exist yet (already-present directories are skipped, so a
-- second run reports an empty list).
--
-- Idempotent: an existing directory is left in place and only re-tightened
-- to 0700, so a release that adds a directory also fixes permissions on the
-- ones created by older builds.
--
-- Called from @trha setup@, not from the normal startup path: the skeleton
-- is a one-time installation step, while every run only needs
-- @~/.trha/settings.yaml@ (and creates the directories it writes to on
-- demand).
initHomeDirs :: FilePath -> IO [FilePath]
initHomeDirs root = catMaybes <$> forM homeLayout (\sub -> do
  let dir = root </> sub
  existed <- doesDirectoryExist dir
  createDirectoryIfMissing True dir
  setFileMode dir 0o700
  pure (if existed then Nothing else Just sub))
