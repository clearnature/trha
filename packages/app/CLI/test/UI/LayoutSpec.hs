module UI.LayoutSpec (spec) where

import Test.Hspec
import UI.Layout

spec :: Spec
spec = do
  describe "sidebarPlacement" $ do
    it "docks from 80 columns up" $ do
      sidebarPlacement 80 `shouldBe` SidebarDocked
      sidebarPlacement 120 `shouldBe` SidebarDocked

    it "falls back to an overlay below 80" $ do
      sidebarPlacement 79 `shouldBe` SidebarOverlay
      sidebarPlacement 40 `shouldBe` SidebarOverlay

  describe "sidebarWidth" $ do
    it "is one third of a docked terminal, clamped to 24..42" $ do
      sidebarWidth 80 `shouldBe` 26
      sidebarWidth 120 `shouldBe` 40
      sidebarWidth 300 `shouldBe` 42

    it "keeps the conversation at least half of an 80-column row" $ do
      messageWidth 80 SidebarOpen `shouldBe` 51

    it "leaves a two-column margin for an overlay" $ do
      sidebarWidth 60 `shouldBe` 42
      sidebarWidth 30 `shouldBe` 28

    it "never returns a non-positive width" $ do
      sidebarWidth 1 `shouldBe` 1
      sidebarWidth 0 `shouldBe` 1

  describe "sidebarRender" $ do
    it "draws nothing when closed" $ do
      sidebarRender 120 SidebarClosed `shouldBe` RenderNone

    it "docks on wide terminals and overlays on narrow ones" $ do
      sidebarRender 100 SidebarOpen `shouldBe` RenderDocked 33
      sidebarRender 60 SidebarOpen `shouldBe` RenderOverlay 42

  describe "messageWidth" $ do
    it "keeps the full width when closed or overlaying" $ do
      messageWidth 120 SidebarClosed `shouldBe` 120
      messageWidth 60 SidebarOpen `shouldBe` 60

    it "subtracts the docked sidebar, its borders and the gap" $ do
      messageWidth 100 SidebarOpen `shouldBe` 64
      messageWidth 80 SidebarOpen `shouldBe` 51

    it "never goes non-positive on a tiny terminal" $ do
      messageWidth 1 SidebarOpen `shouldBe` 1
      messageWidth 1 SidebarClosed `shouldBe` 1

  describe "toggleSidebar" $ do
    it "round-trips" $ do
      toggleSidebar SidebarOpen `shouldBe` SidebarClosed
      toggleSidebar (toggleSidebar SidebarOpen) `shouldBe` SidebarOpen
