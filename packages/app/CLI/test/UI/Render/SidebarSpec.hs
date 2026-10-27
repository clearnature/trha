{-# LANGUAGE OverloadedStrings #-}

module UI.Render.SidebarSpec (spec) where

import Test.Hspec
import Data.List (isPrefixOf, isSuffixOf)
import qualified Data.Text as T
import Core.Types (AgentEntry(..), TodoItem(..), TodoStatus(..), Usage(..), mkUsage)
import UI.I18n (Lang(..))
import UI.Render.Sidebar

sampleUsage :: Usage
sampleUsage = mkUsage 120 30 150

sampleTodos :: [TodoItem]
sampleTodos =
  [ TodoItem "1" "wire layout" TodoDone
  , TodoItem "2" "render sections" TodoInProgress
  , TodoItem "3" "write docs" TodoPending ]

texts :: [SidebarLine] -> [String]
texts = map (T.unpack . slText)

spec :: Spec
spec = do
  describe "sidebarLines" $ do
    it "keeps the seven sections in order" $ do
      texts (sidebarLines 40 emptySidebarData)
        `shouldBe` [ "Context", "no usage yet"
                   , "CWD", "unknown"
                   , "Files", "no files"
                   , "Goal", "no goal"
                   , "Instructions", "none detected"
                   , "TODO", "No tasks"
                   , "Agents", "no agents"
                   , "LSP", "off"
                   , "MCP", "none configured"
                   , "Session", "no session" ]

    it "renders cwd, files, goal and instruction files" $ do
      let d = emptySidebarData
                { sdCwd = Just "/work/trha"
                , sdFiles = ["src/Main.hs", "README.md"]
                , sdGoal = Just "ship the TUI port"
                , sdInstructions = ["AGENTS.md", "REASONIX.md"] }
          ls = texts (sidebarLines 40 d)
      ls `shouldSatisfy` elem "/work/trha"
      ls `shouldSatisfy` elem "src/Main.hs"
      ls `shouldSatisfy` elem "ship the TUI port"
      ls `shouldSatisfy` elem "AGENTS.md"
      ls `shouldSatisfy` elem "REASONIX.md"

    it "renders usage and context occupancy" $ do
      let d = emptySidebarData { sdUsage = Just sampleUsage, sdCtxSize = Just 1000 }
          ls = texts (sidebarLines 40 d)
      ls `shouldSatisfy` elem "in 120 · out 30"
      ls `shouldSatisfy` elem "total 150 · ctx 12%"

    it "omits occupancy when the context size is unknown" $ do
      let d = emptySidebarData { sdUsage = Just sampleUsage }
      texts (sidebarLines 40 d) `shouldSatisfy` elem "total 150"

    it "renders every todo with its status glyph" $ do
      let ls = texts (sidebarLines 40 emptySidebarData { sdTodos = sampleTodos })
      ls `shouldSatisfy` elem "● wire layout"
      ls `shouldSatisfy` elem "◐ render sections"
      ls `shouldSatisfy` elem "○ write docs"

    it "shows the session id, title and model when present" $ do
      let d = emptySidebarData
                { sdSessionId = Just "s1", sdTitle = Just "fix parser"
                , sdModel = "glm-5" }
          ls = texts (sidebarLines 40 d)
      ls `shouldSatisfy` elem "id s1"
      ls `shouldSatisfy` elem "title fix parser"
      ls `shouldSatisfy` elem "model glm-5"

    it "omits the model line when empty" $ do
      let ls = texts (sidebarLines 40 emptySidebarData { sdSessionId = Just "s1" })
      ls `shouldSatisfy` (not . any ("model" `isPrefixOf`))

    it "truncates to the column width" $ do
      let d = emptySidebarData
                { sdTodos = [TodoItem "1" "a very long task subject indeed" TodoPending] }
          ls = sidebarLines 10 d
      map (T.length . slText) ls `shouldSatisfy` all (<= 10)
      texts ls `shouldSatisfy` any ("…" `isSuffixOf`)

  describe "agentTreeLines" $ do
    it "indents children and marks the current session" $ do
      let as = [ AgentEntry "root" Nothing, AgentEntry "child" (Just "root"), AgentEntry "other" Nothing ]
      agentTreeLines (Just "child") as
        `shouldBe` [ "· root", "  ● child", "· other" ]

    it "is empty without agents" $
      agentTreeLines Nothing [] `shouldBe` []

  describe "sidebarHint" $ do
    it "names both shortcuts on one line" $ do
      sidebarHint En `shouldSatisfy` T.isInfixOf "Ctrl+B"
      sidebarHint En `shouldSatisfy` T.isInfixOf "Ctrl+Q"
      sidebarHint En `shouldSatisfy` (not . T.any (== '\n'))
    it "is localised" $ do
      sidebarHint Zh `shouldSatisfy` T.isInfixOf "侧栏"
      sidebarHint Zh `shouldSatisfy` T.isInfixOf "退出"
