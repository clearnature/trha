{-# LANGUAGE OverloadedStrings #-}

-- | Specs for the interaction-layer model (IA §6).
--
-- The load-bearing assertion is coverage: every registered slash command must
-- have exactly one declared layer.  That is what turns "we ported the command
-- but forgot to wire it" into a test failure instead of a silent fall-through
-- to a synchronous handler that freezes the UI (IA §6.4 D3).
module UI.InteractionSpec (spec) where

import Data.List (nub, sort)
import qualified Data.Text as T
import Test.Hspec

import UI.Commands.Registry (slashRegistry, scCommand)
import UI.Interaction

registeredNames :: [T.Text]
registeredNames = map scCommand slashRegistry

spec :: Spec
spec = describe "UI.Interaction" $ do
  describe "command → layer table" $ do
    it "classifies every registered command (no fall-through)" $
      unknownLayerCommands registeredNames `shouldBe` []

    it "has no command that is not in the registry" $
      [ n | (n, _) <- layerTable, n `notElem` registeredNames ] `shouldBe` []

    it "assigns each command exactly once" $
      length (nub (map fst layerTable)) `shouldBe` length layerTable

    it "covers the registry one-to-one" $
      length layerTable `shouldBe` length registeredNames

    it "leaves no command layer empty except the wizard (entered from /provider)" $
      [ c | c <- [minBound .. maxBound], null (commandsInLayer c), c /= CmdWizard ]
        `shouldBe` []

  describe "regressions this table exists to catch" $ do
    it "keeps the ten turn commands off the synchronous path (D3)" $
      map commandLayerOf
        [ "/retry", "/btw", "/recap", "/compact", "/queue"
        , "/steer", "/fork", "/branch", "/loop", "/workflow"
        ] `shouldBe` replicate 10 (Just CmdAsync)

    it "routes /vim through the terminal handover (D5)" $
      commandLayerOf "/vim" `shouldBe` Just CmdTerminal

    it "keeps /switch async so the shell state can be refreshed (D7)" $
      commandLayerOf "/switch" `shouldBe` Just CmdAsync

    it "classifies bridge-reading commands as async, never reply" $
      map commandLayerOf
        [ "/usage", "/mcp", "/lsp", "/session-info"
        , "/doctor", "/goal", "/graph", "/plugins"
        ] `shouldBe` replicate 8 (Just CmdAsync)

    it "opens settings as a full-screen panel, not a dialog (I3)" $
      commandLayerOf "/settings" `shouldBe` Just CmdPanel

    it "needs a confirmation picker for /delete" $
      commandLayerOf "/delete" `shouldBe` Just CmdPicker

    it "has exactly the two exit aliases plus /stop" $
      sort (commandsInLayer CmdExit) `shouldBe` ["/exit", "/quit", "/stop"]

  describe "escape priority" $ do
    it "lists every layer exactly once" $
      sort escapeOrder `shouldBe` allLayers

    it "lets the full-screen settings panel win over an open dialog (D1/D4)" $
      resolveEscapeLayer [LayerEditor, LayerDialog, LayerSettings]
        `shouldBe` LayerSettings

    it "cancels the wizard before closing inline popups (D2)" $
      resolveEscapeLayer [LayerEditor, LayerCompletion, LayerPalette, LayerWizard]
        `shouldBe` LayerWizard

    it "closes the completion popup before the palette" $
      resolveEscapeLayer [LayerEditor, LayerPalette, LayerCompletion]
        `shouldBe` LayerCompletion

    it "pops the dialog stack before leaving a turn" $
      resolveEscapeLayer [LayerEditor, LayerTurn, LayerDialog]
        `shouldBe` LayerDialog

    it "falls back to the editor when nothing is open" $
      resolveEscapeLayer [] `shouldBe` LayerEditor

    it "ignores layers that are not active" $
      resolveEscapeLayer [LayerEditor] `shouldBe` LayerEditor

  describe "ordinary-key ownership" $ do
    it "puts settings above dialogs" $
      take 2 keyOwnerOrder `shouldBe` [LayerSettings, LayerDialog]

    it "puts the transient leader above the editor" $
      keyOwnerOrder `shouldBe` [LayerSettings, LayerDialog, LayerLeader, LayerEditor]

    it "does not let inline layers own keys directly" $
      filter (`elem` keyOwnerOrder) [LayerCompletion, LayerPalette]
        `shouldBe` []
