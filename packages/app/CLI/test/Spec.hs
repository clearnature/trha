module Main (main) where

import Test.Hspec
import qualified Config.SettingsSpec
import qualified Config.HomeSpec
import qualified Core.ArgsSpec
import qualified Core.HTTPSpec
import qualified Core.ReplaySpec
import qualified Core.ExportSpec
import qualified Core.TurnStatsSpec
import qualified Core.EffortContractSpec
import qualified Core.TranscriptSpec
import qualified Core.MemorySpec
import qualified Core.RunLogSpec
import qualified Core.RunStateSpec
import qualified Core.StatePathsSpec
import qualified Core.ProjectStoreSpec
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
import qualified UI.SetupSpec
import qualified UI.IndexCacheSpec
import qualified UI.CustomCommandsSpec
import qualified UI.Render.ToolCardSpec
import qualified UI.Render.ToolSummarySpec
import qualified UI.Render.MessageSpec
import qualified BridgeDeltaSpec
import qualified UI.EventSpec
import qualified UI.ThemeSpec
import qualified UI.InputHistorySpec
import qualified UI.DialogSpec
import qualified UI.InteractionSpec
import qualified UI.LayoutSpec
import qualified UI.CompletionSpec
import qualified UI.KeysSpec
import qualified UI.SkillsSpec
import qualified UI.SelectionSpec
import qualified UI.TimeStampSpec
import qualified UI.StashSpec
import qualified UI.TextWidthSpec
import qualified UI.FrecencySpec
import qualified UI.ModelPrefsSpec
import qualified UI.Render.DiffSpec
import qualified UI.Render.SidebarSpec

main :: IO ()
main = hspec $ do
  Core.ArgsSpec.spec
  Core.HTTPSpec.spec
  Config.SettingsSpec.spec
  Config.HomeSpec.spec
  Core.ReplaySpec.spec
  Core.ExportSpec.spec
  Core.TurnStatsSpec.spec
  Core.EffortContractSpec.spec
  Core.TranscriptSpec.spec
  Core.MemorySpec.spec
  Core.RunLogSpec.spec
  Core.RunStateSpec.spec
  Core.StatePathsSpec.spec
  Core.ProjectStoreSpec.spec
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
  UI.SetupSpec.spec
  UI.IndexCacheSpec.spec
  UI.CustomCommandsSpec.spec
  UI.Render.ToolCardSpec.spec
  UI.Render.ToolSummarySpec.spec
  UI.Render.MessageSpec.spec
  BridgeDeltaSpec.spec
  UI.EventSpec.spec
  UI.ThemeSpec.spec
  UI.InputHistorySpec.spec
  UI.DialogSpec.spec
  UI.InteractionSpec.spec
  UI.LayoutSpec.spec
  UI.CompletionSpec.spec
  UI.KeysSpec.spec
  UI.SkillsSpec.spec
  UI.SelectionSpec.spec
  UI.TimeStampSpec.spec
  UI.StashSpec.spec
  UI.TextWidthSpec.spec
  UI.FrecencySpec.spec
  UI.ModelPrefsSpec.spec
  UI.Render.DiffSpec.spec
  UI.Render.SidebarSpec.spec
