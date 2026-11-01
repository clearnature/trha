{-# LANGUAGE OverloadedStrings #-}

module UI.Render.FilePartSpec (spec) where

import Test.Hspec
import UI.Render.FilePart

spec :: Spec
spec = do
  describe "filePartsOf" $ do
    it "finds a clipboard image token" $
      filePartsOf "look [image: /tmp/paste/a.png]"
        `shouldBe` [FileRef FkImage "/tmp/paste/a.png"]

    it "finds image and voice tokens in order" $
      filePartsOf "[image: a.png] and [voice: b.wav]"
        `shouldBe` [FileRef FkImage "a.png", FileRef FkVoice "b.wav"]

    it "keeps Windows paths intact (drive colon is not a separator)" $
      filePartsOf "shot [image: C:\\Users\\me\\shot.png]"
        `shouldBe` [FileRef FkImage "C:\\Users\\me\\shot.png"]

    it "ignores square brackets that are not attachments" $
      filePartsOf "see [1] and [note: hi]" `shouldBe` []

    it "drops duplicate references" $
      filePartsOf "[image: a.png] [image: a.png]"
        `shouldBe` [FileRef FkImage "a.png"]

    it "returns nothing for plain prose" $
      filePartsOf "just a sentence" `shouldBe` []

  describe "stripFileTokens" $ do
    it "removes the token and collapses the gap" $
      stripFileTokens "look [image: a.png] here" `shouldBe` "look here"

    it "leaves prose without tokens byte-identical" $ do
      let prose = "line one\nline two"
      stripFileTokens prose `shouldBe` prose

    it "drops a trailing token without leaving a space" $
      stripFileTokens "done [voice: b.wav]" `shouldBe` "done"

    it "keeps non-attachment brackets" $
      stripFileTokens "[1] stays [image: a.png]" `shouldBe` "[1] stays"

  describe "filePartLine" $ do
    it "labels each kind and keeps the path" $ do
      filePartLine (FileRef FkImage "/tmp/a.png") `shouldBe` "▣ image  /tmp/a.png"
      filePartLine (FileRef FkVoice "/tmp/a.wav") `shouldBe` "▣ voice  /tmp/a.wav"
      filePartLine (FileRef FkFile "/tmp/a.txt")  `shouldBe` "▣ file  /tmp/a.txt"

    it "maps a list to rows" $
      filePartLines [FileRef FkImage "a.png", FileRef FkVoice "b.wav"]
        `shouldBe` ["▣ image  a.png", "▣ voice  b.wav"]
