{-# LANGUAGE OverloadedStrings #-}

module UI.SkillsSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import UI.Skills

sample :: String
sample = unlines
  [ "---"
  , "name: brooks-review"
  , "description: \"Review a diff for structural debt\""
  , "---"
  , ""
  , "# Body"
  ]

spec :: Spec
spec = do
  describe "parseSkill" $ do
    it "reads name and description from the frontmatter" $ do
      let s = parseSkill "/skills/brooks-review/SKILL.md" (T.pack sample)
      skName s `shouldBe` "brooks-review"
      skDescription s `shouldBe` "Review a diff for structural debt"
      skPath s `shouldBe` "/skills/brooks-review/SKILL.md"

    it "falls back to the directory name for SKILL.md" $ do
      let s = parseSkill "/skills/dir-name/SKILL.md" "no frontmatter"
      skName s `shouldBe` "dir-name"
      skDescription s `shouldBe` ""

    it "falls back to the file name for flat markdown" $ do
      let s = parseSkill "/skills/quick.md" "no frontmatter"
      skName s `shouldBe` "quick"

  describe "skillsFromFiles" $ do
    it "keeps the first skill per name and sorts by name" $ do
      let files =
            [ ("/a/zeta/SKILL.md", "---\nname: zeta\ndescription: first\n---\n")
            , ("/b/alpha/SKILL.md", "---\nname: alpha\ndescription: a\n---\n")
            , ("/c/zeta/SKILL.md", "---\nname: zeta\ndescription: second\n---\n")
            ]
      map skName (skillsFromFiles files) `shouldBe` ["alpha", "zeta"]
      map skDescription (skillsFromFiles files) `shouldBe` ["a", "first"]

  describe "skillDirList" $ do
    it "puts project .agents first and an explicit dir last" $ do
      skillDirList "/proj" "/home/u" (Just "/extra")
        `shouldBe` [ "/proj/.agents/skills", "/proj/.trha/skills"
                   , "/home/u/.agents/skills", "/home/u/.trha/skills"
                   , "/extra" ]

    it "includes the open-standard .agents tree by default" $ do
      skillDirList "/proj" "/home/u" Nothing
        `shouldSatisfy` elem "/home/u/.agents/skills"
