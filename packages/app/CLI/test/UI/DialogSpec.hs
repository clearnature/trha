{-# LANGUAGE OverloadedStrings #-}

module UI.DialogSpec (spec) where

import Test.Hspec
import Core.Types (ModelInfo(..))
import Core.SessionSummary (SessionSummary(..))
import UI.Dialog

sampleModels :: [ModelInfo]
sampleModels = [ ModelInfo "a" "" 1000, ModelInfo "b" "" 2000 ]

sampleSessions :: [SessionSummary]
sampleSessions = [ SessionSummary "s1" "t" 1 Nothing Nothing Nothing ]

spec :: Spec
spec = do
  describe "stack" $ do
    it "push and pop round-trip" $ do
      let s0 = stackPush (DialogModels sampleModels 0) emptyStack
      stackTop s0 `shouldBe` Just (DialogModels sampleModels 0)
      stackPop s0 `shouldBe` emptyStack

    it "pops from the top only" $ do
      let s1 = stackPush (DialogSessions sampleSessions 0)
             $ stackPush (DialogModels sampleModels 0) emptyStack
      stackTop s1 `shouldBe` Just (DialogSessions sampleSessions 0)
      stackTop (stackPop s1) `shouldBe` Just (DialogModels sampleModels 0)

    it "empty stack: top is Nothing, pop is a no-op, stackNull holds" $ do
      stackTop emptyStack `shouldBe` Nothing
      stackPop emptyStack `shouldBe` emptyStack
      stackNull emptyStack `shouldBe` True

    it "stackNull is False once something is pushed" $ do
      stackNull (stackPush (DialogModels sampleModels 0) emptyStack) `shouldBe` False

  describe "selection" $ do
    it "moves the model picker selection and clamps at the end" $ do
      dialogMoveSel 1 (DialogModels sampleModels 0) `shouldBe` DialogModels sampleModels 1
      dialogMoveSel 1 (DialogModels sampleModels 1) `shouldBe` DialogModels sampleModels 1

    it "clamps at the start" $ do
      dialogMoveSel (-5) (DialogSessions sampleSessions 0) `shouldBe` DialogSessions sampleSessions 0

    it "does not move within an empty list" $ do
      dialogMoveSel 1 (DialogModels [] 0) `shouldBe` DialogModels [] 0

  describe "commands editing" $ do
    it "appends a character and resets the selection" $ do
      let d1 = dialogCommandsAppend 'h' (DialogCommands [] "/" 2)
      dialogCommandsQuery d1 `shouldBe` "/h"
      dialogCommandsSelected d1 `shouldBe` 0

    it "delete removes the last query character" $ do
      dialogCommandsDelete (DialogCommands [] "/hel" 0) `shouldBe` DialogCommands [] "/he" 0

    it "delete never eats the seed slash" $ do
      dialogCommandsDelete (DialogCommands [] "/" 0) `shouldBe` DialogCommands [] "/" 0

    it "counts only the filtered items" $ do
      dialogCount (DialogCommands [] "/" 0) `shouldBe` 0

  describe "escape hierarchy" $ do
    it "clears a text selection first" $ do
      resolveEscape (EscFlags True True True True) `shouldBe` EscClearSelection

    it "pops the dialog stack before anything else" $ do
      resolveEscape (EscFlags False True True True) `shouldBe` EscPopDialog

    it "exits shell mode next" $ do
      resolveEscape (EscFlags False False True True) `shouldBe` EscExitShell

    it "closes the autocomplete popup" $ do
      resolveEscape (EscFlags False False False True) `shouldBe` EscCloseComplete

    it "rejects at the approval layer (escape binds to reject)" $ do
      resolveEscape (EscFlags False False False False) `shouldBe` EscApprovalDeny

  describe "approval dialog" $ do
    it "moves within the three options (once/always/reject)" $ do
      dialogMoveSel 1 (DialogApproval "ask" "bash" ["ls"] 0)
        `shouldBe` DialogApproval "ask" "bash" ["ls"] 1
      dialogMoveSel 1 (DialogApproval "ask" "bash" ["ls"] 2)
        `shouldBe` DialogApproval "ask" "bash" ["ls"] 2
    it "moves within the two confirm options and clamps" $ do
      dialogMoveSel 1 (DialogConfirm "persist?" 0) `shouldBe` DialogConfirm "persist?" 1
      dialogMoveSel 5 (DialogConfirm "persist?" 0) `shouldBe` DialogConfirm "persist?" 1

  describe "double-escape arming" $ do
    it "first press arms without firing" $ do
      escPress False False `shouldBe` (False, True)

    it "second press within the window fires and disarms" $ do
      escPress True True `shouldBe` (True, False)

    it "press outside the window re-arms only" $ do
      escPress False True `shouldBe` (False, True)

  describe "escape wiring" $ do
    it "idle presses never fire and leave no arm behind" $ do
      escWiring False True True `shouldBe` (False, False)
      escWiring False False False `shouldBe` (False, False)

    it "the first running press arms" $ do
      escWiring True False False `shouldBe` (False, True)

    it "the second press within the window fires and disarms" $ do
      escWiring True True True `shouldBe` (True, False)

    it "a third press after firing re-arms instead of firing again" $ do
      -- after a fire the timestamp is cleared, so the next press sees
      -- withinWindow = False and armed = False
      escWiring True False False `shouldBe` (False, True)

  describe "approval options" $ do
    it "offers once/always/reject for ordinary tools" $ do
      approvalOptions "write" ["a.txt"]
        `shouldBe` [ApprovalOnce, ApprovalAlways, ApprovalReject]

    it "offers once/always/reject for harmless shell commands" $ do
      approvalOptions "bash" ["ls -la"]
        `shouldBe` [ApprovalOnce, ApprovalAlways, ApprovalReject]

    it "drops always for destructive shell verbs" $ do
      approvalOptions "bash" ["rm -rf build"] `shouldBe` [ApprovalOnce, ApprovalReject]
      approvalOptions "shell" ["sudo rm -rf /"] `shouldBe` [ApprovalOnce, ApprovalReject]
      approvalOptions "run_shell" ["FOO=1 mv a b"] `shouldBe` [ApprovalOnce, ApprovalReject]

    it "drops always for destructive git commands" $ do
      approvalOptions "bash" ["git clean -fdx"] `shouldBe` [ApprovalOnce, ApprovalReject]
      approvalOptions "bash" ["git reset --hard HEAD~1"] `shouldBe` [ApprovalOnce, ApprovalReject]

    it "keeps always for non-destructive git commands" $ do
      approvalOptions "bash" ["git status"] `shouldBe` [ApprovalOnce, ApprovalAlways, ApprovalReject]

    it "does not treat non-shell tools as destructive" $ do
      isDestructiveShell "write" ["rm -rf /"] `shouldBe` False

    it "counts and clamps the card's options" $ do
      dialogCount (DialogApproval "ask" "bash" ["rm -rf build"] 0) `shouldBe` 2
      dialogCount (DialogApproval "ask" "bash" ["ls"] 0) `shouldBe` 3
      dialogMoveSel 1 (DialogApproval "ask" "bash" ["rm -rf build"] 1)
        `shouldBe` DialogApproval "ask" "bash" ["rm -rf build"] 1
