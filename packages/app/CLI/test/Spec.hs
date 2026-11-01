module Main (main) where

import Test.Hspec
import System.IO (hSetEncoding, stdout, stderr, utf8)
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
import qualified UI.Render.FilePartSpec
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

-- | Windows 控制台默认代码页（如 936）编码不了 ↔ 之类符号，Hspec 打印测试名
-- 时会在 commitBuffer 抛异常，把整轮测试判成 FAIL。统一按 UTF-8 输出。
ensureUtf8Output :: IO ()
ensureUtf8Output = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8

main :: IO ()
main = ensureUtf8Output >> hspec testSuite

testSuite :: Spec
testSuite = do
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
  UI.Render.FilePartSpec.spec
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
