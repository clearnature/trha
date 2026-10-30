{-# LANGUAGE OverloadedStrings #-}

module UI.Render.ToolSummarySpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import UI.Render.ToolCard
import UI.Render.ToolSummary

card :: Text -> [Text] -> Maybe ToolStatus -> Maybe Int -> [Text] -> ToolCard
card name args status dur out = ToolCard (T.unpack name) args status dur out "" Nothing

spec :: Spec
spec = do
  describe "toolKindOf" $ do
    it "maps the shell family, aliases included" $ do
      map toolKindOf ["bash", "shell", "exec_command", "pwsh"]
        `shouldBe` [KShell, KShell, KShell, KShell]

    it "maps read/search/edit/write families" $ do
      map toolKindOf ["read", "read_file", "glob", "grep", "edit", "apply_patch", "write"]
        `shouldBe` [KRead, KRead, KSearch, KSearch, KEdit, KEdit, KWrite]

    it "maps network, agent, ask, skill, present and plan" $ do
      map toolKindOf
        ["web_fetch", "web_search", "subagent", "workflow", "team_task_list",
         "ask_user_question", "skill", "present", "exit_plan_mode"]
        `shouldBe` [KNet, KNet, KAgent, KAgent, KAgent, KAsk, KSkill, KPresent, KPlan]

    it "falls back to the generic shape" $ do
      toolKindOf "mcp__something" `shouldBe` KGeneric

  describe "argOf" $ do
    it "reads key=value arguments" $
      argOf "command" ["command=ls -la", "timeout=10"] `shouldBe` Just "ls -la"

    it "misses on a raw JSON fallback string" $
      argOf "command" ["{\"command\":\"ls\"}"] `shouldBe` Nothing

  describe "toolHeadline" $ do
    it "shows the shell command and status" $ do
      toolHeadline (card "bash" ["command=ls -la"] (Just ToolSucceeded) (Just 12) [])
        `shouldBe` "[tool] bash ✓ 12ms ls -la"

    it "shows the edited path" $ do
      toolHeadline (card "edit" ["path=src/Foo.hs"] (Just ToolSucceeded) Nothing [])
        `shouldBe` "[tool] edit ✓ src/Foo.hs"

    it "shows a search pattern" $ do
      toolHeadline (card "grep" ["pattern=TODO"] Nothing Nothing [])
        `shouldBe` "[tool] grep (running…) TODO"

    it "truncates long summaries to the card width" $ do
      let long = T.replicate 100 "x"
      T.length (toolHeadline (card "bash" ["command=" <> long] Nothing Nothing []))
        `shouldSatisfy` (<= cardWidth)

  describe "toolDetailLines" $ do
    it "renders a shell command with a $ prefix" $
      toolDetailLines (card "bash" ["command=ls -la"] Nothing Nothing [])
        `shouldBe` ["  $ ls -la"]

    it "adds diff counts for an edit card" $ do
      toolDetailLines (card "edit" ["path=a.txt"] (Just ToolSucceeded) Nothing ["+one", "-two"])
        `shouldBe` ["  a.txt  +1/-1"]

    it "renders a present card body" $ do
      toolDetailLines (card "present" ["title=Sweep", "body=done"] Nothing Nothing [])
        `shouldBe` ["  Sweep", "  │ done"]

  describe "presentCard" $ do
    it "extracts title and body" $
      presentCard (card "present" ["title=Sweep", "body=done"] Nothing Nothing [])
        `shouldBe` Just ("Sweep", "done")

    it "is Nothing for other tools" $
      presentCard (card "bash" ["command=ls"] Nothing Nothing []) `shouldBe` Nothing

  describe "outputStats" $ do
    it "counts added/removed lines and ignores file headers" $
      outputStats ["--- a", "+++ b", "+x", "-y", " ctx"]
        `shouldBe` (1, 1)
