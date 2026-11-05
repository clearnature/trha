{-# LANGUAGE OverloadedStrings #-}

-- | Single source of truth for slash commands, shared by the TUI quick
-- picker, the REPL command parser and the haskeline tab completion
-- (Phase 1.6 unification; cf. Reasonix slash_registry.go).
--
-- Pure module -- no IO, no brick -- so parsing/registry logic is
-- unit-testable.
module UI.Commands.Registry
  ( -- * Commands
    Command(..)
  , parseCommand
  , parseCommandWith
    -- * Settings keys
  , settingKeys
  , parseSettingValue
  , suggestSettingKey
  , formatSettings
    -- * Machine-readable schema
  , settingsSchemaJson
  , defaultFor
  , settingKeyDocs
    -- * Registry
  , SlashCommand(..)
  , slashRegistry
  , CommandGroup(..)
  , commandGroups
  , groupKey
  , groupTitle
  , groupOf
  , groupMembers
  , pickerItems
  , pickerItemsGrouped
  , completions
  , isKnownCommand
  , registryHelp
  , helpTextFor
  ) where

import Data.Aeson (Value(..), object, toJSON, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Core.Types (CLIConfig(..), defaultCLIConfig)
import UI.Commands.Registry.Table (SlashCommand(..), slashRegistry)
import UI.Commands.Registry.Types
  ( Command(..), CommandGroup(..), commandGroups, groupKey, groupMembers
  , groupOf, groupTitle )
import UI.Commands.Registry.Parser (parseCommand, parseCommandWith)
import UI.Commands.Registry.Settings
  ( defaultFor, formatSettings, parseSettingValue, settingKeyDocs, settingKeys
  , suggestSettingKey, settingsSchemaJson )
import UI.I18n (Lang(..), tr)
import UI.Render.Picker (PickerItem(..))

-- | Parsed REPL/TUI command.
pickerItems :: Lang -> [PickerItem]
pickerItems lang =
  [ PickerItem (scCommand sc) (scCommand sc) (tr lang (scDesc sc))
  | sc <- slashRegistry
  , scPicker sc
  ]

-- | Picker items grouped by function, in display order; empty groups are
-- dropped and each group is sorted by command name.
pickerItemsGrouped :: Lang -> [(CommandGroup, [PickerItem])]
pickerItemsGrouped lang =
  [ (g, sortOn (T.toLower . piId) items)
  | g <- commandGroups
  , let items = [ PickerItem (scCommand sc) (scCommand sc) (tr lang (scDesc sc))
                | sc <- slashRegistry, scPicker sc, groupOf (scCommand sc) == g ]
  , not (null items)
  ]

-- | Tab-completion candidates (canonical command names).
completions :: [Text]
completions = map scCommand slashRegistry

-- | True when the leading word names a registered command (parameterised
-- commands match both bare and parameterised forms).
isKnownCommand :: Text -> Bool
isKnownCommand input =
  case T.words (T.strip input) of
    (w : _) | "/" `T.isPrefixOf` w ->
      any ((== w) . scCommand) slashRegistry
    _ -> False

-- | Help text generated from the registry, rendered in the active
-- language (descriptions are translated; command names never are).
registryHelp :: Lang -> Text
registryHelp lang = T.unlines $
  (tr lang "Commands:" : concatMap section commandGroups)
  ++ [""] ++ keySection
  where
    maxLen = maximum (map (T.length . scCommand) slashRegistry)
    section g = case sortOn scCommand [ sc | sc <- slashRegistry, groupOf (scCommand sc) == g ] of
      []   -> []
      scs  -> ("  " <> groupTitle lang g) : map (helpLine lang) scs
    helpLine l sc =
      let pad = T.replicate (maxLen - T.length (scCommand sc) + 2) " "
      in "  " <> scCommand sc <> pad <> tr l (scDesc sc)
    -- Keys are shell-local; stop is the only service-level command here.
    keySection =
      [ tr lang "Keys:"
      , "  Ctrl+Q        " <> tr lang "quit"
      , "  Ctrl+C        " <> tr lang "interrupt; press twice to quit"
      , "  Ctrl+D        " <> tr lang "quit when the prompt is empty"
      , "  /stop         " <> tr lang "stop the kernel and scheduler"
      ]

-- | Canonical setting keys (the fields of CLIConfig a user may persist).
helpTextFor :: Lang -> Text
helpTextFor lang = T.unlines $
  T.lines (registryHelp lang)
    ++ [ ""
       , tr lang "Quick picker:"
       , tr lang "  Type a slash prefix and press Enter to open the command menu;"
       , tr lang "  keep typing to filter, ↑/↓ to move, Enter to run, Esc to close."
       , ""
       , tr lang "Keys:"
       , tr lang "  PgUp / PgDn       Scroll messages"
       , tr lang "  Ctrl+Home / End   Jump to top / bottom"
       , tr lang "  Ctrl+O            Fold / expand thinking and tool cards"
       , tr lang "  Alt+↑ / Alt+↓     Move the tool-card focus"
       , tr lang "  Shift+Tab         Cycle permission posture"
       , tr lang "  Ctrl+Y            Toggle YOLO"
       , tr lang "  Esc Esc           Interrupt the running turn"
       , tr lang "  Ctrl+C            Interrupt · copy selection · clear draft · quit"
       , tr lang "  Ctrl+S            Submit the draft (same as Enter)"
       , tr lang "  Ctrl+Enter        Steer the running turn with the draft"
       , tr lang "  Ctrl+L            Clear the transcript view (history kept)"
       , tr lang "  Alt+V             Paste clipboard text"
       , tr lang "  Ctrl+G            Expand folded pastes"
       , tr lang "  Ctrl+B            Show / hide the sidebar"
       , tr lang "  Ctrl+X            Leader (b/p/m/s/,/?/i)"
       , tr lang "  Ctrl+Q / Ctrl+D   Quit"
       ]
