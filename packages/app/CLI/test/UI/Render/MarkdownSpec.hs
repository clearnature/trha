{-# LANGUAGE OverloadedStrings #-}

module UI.Render.MarkdownSpec (spec) where

import Test.Hspec
import UI.Render.Markdown
import qualified Data.Text as T

spec :: Spec
spec = do
  describe "parseMarkdown" $ do
    it "parses a plain paragraph" $ do
      parseMarkdown "hello world"
        `shouldBe` [ MdParagraph [MdPlain "hello world"] ]

    it "splits paragraphs on blank lines" $ do
      parseMarkdown "first\n\nsecond"
        `shouldBe` [ MdParagraph [MdPlain "first"]
                   , MdParagraph [MdPlain "second"] ]

    it "parses bold spans" $ do
      parseMarkdown "run **build** now"
        `shouldBe` [ MdParagraph [ MdPlain "run "
                                 , MdBold "build"
                                 , MdPlain " now" ] ]

    it "parses inline code spans" $ do
      parseMarkdown "use `read_file` please"
        `shouldBe` [ MdParagraph [ MdPlain "use "
                                 , MdCode "read_file"
                                 , MdPlain " please" ] ]

    it "parses mixed inline formatting" $ do
      parseMarkdown "**note**: see `main`"
        `shouldBe` [ MdParagraph [ MdBold "note"
                                 , MdPlain ": see "
                                 , MdCode "main" ] ]

    it "parses a fenced code block with language" $ do
      parseMarkdown "```hs\nmain = pure ()\n```"
        `shouldBe` [ MdCodeBlock "hs" "main = pure ()" ]

    it "keeps multi-line code block bodies intact" $ do
      parseMarkdown "```python\ndef f():\n    return 1\n```"
        `shouldBe` [ MdCodeBlock "python" "def f():\n    return 1" ]

    it "treats an unterminated fence as a code block to EOF" $ do
      parseMarkdown "```text\nline1\nline2"
        `shouldBe` [ MdCodeBlock "text" "line1\nline2" ]

    it "mixes paragraphs and code blocks in order" $ do
      parseMarkdown "intro\n```sh\necho hi\n```\noutro"
        `shouldBe` [ MdParagraph [MdPlain "intro"]
                   , MdCodeBlock "sh" "echo hi"
                   , MdParagraph [MdPlain "outro"] ]

    it "parses an empty document" $ do
      parseMarkdown "" `shouldBe` []

    it "treats whitespace-only input as empty" $ do
      parseMarkdown "  \n\n " `shouldBe` []

  describe "renderMarkdownText" $ do
    it "strips bold and inline-code markers" $ do
      renderMarkdownText "run **build** with `x`"
        `shouldBe` "run build with x"

    it "keeps code block bodies" $ do
      renderMarkdownText "```hs\nmain = pure ()\n```"
        `shouldBe` "main = pure ()"

    it "keeps Chinese text intact" $ do
      renderMarkdownText "你好 **世界**"
        `shouldBe` "你好 世界"

    it "joins paragraphs with blank lines" $ do
      renderMarkdownText "a\n\nb" `shouldBe` "a\n\nb"
