module Main (main) where

import Test.Hspec
import qualified Config.SettingsSpec
import qualified Core.ArgsSpec
import qualified Core.HTTPSpec
import qualified Core.ReplaySpec
import qualified Core.TranscriptSpec
import qualified Core.SSESpec
import qualified Core.TypesSpec
import qualified Core.SessionSummarySpec
import qualified UI.Commands.RegistrySpec
import qualified UI.I18nSpec
import qualified UI.CommandsSpec
import qualified UI.Render.FooterSpec
import qualified UI.Render.MarkdownSpec
import qualified UI.Render.PickerSpec
import qualified UI.StatsViewSpec
import qualified UI.StatusInfoSpec
import qualified UI.SettingsViewSpec
import qualified UI.Render.ToolCardSpec
import qualified BridgeDeltaSpec
import qualified UI.EventSpec
import qualified UI.ThemeSpec
import qualified UI.InputHistorySpec

main :: IO ()
main = hspec $ do
  Core.ArgsSpec.spec
  Core.HTTPSpec.spec
  Config.SettingsSpec.spec
  Core.ReplaySpec.spec
  Core.TranscriptSpec.spec
  Core.SSESpec.spec
  Core.TypesSpec.spec
  Core.SessionSummarySpec.spec
  UI.Commands.RegistrySpec.spec
  UI.I18nSpec.spec
  UI.CommandsSpec.spec
  UI.Render.FooterSpec.spec
  UI.Render.MarkdownSpec.spec
  UI.Render.PickerSpec.spec
  UI.StatsViewSpec.spec
  UI.StatusInfoSpec.spec
  UI.SettingsViewSpec.spec
  UI.Render.ToolCardSpec.spec
  BridgeDeltaSpec.spec
  UI.EventSpec.spec
  UI.ThemeSpec.spec
  UI.InputHistorySpec.spec
