{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Skill discovery for the palette (MiMo parity).
--
-- Skills are @SKILL.md@ files with a tiny frontmatter block:
--
-- > ---
-- > name: brooks-review
-- > description: Review a diff for structural debt
-- > ---
-- > body…
--
-- They live either as @<dir>/<name>/SKILL.md@ or @<dir>/<name>.md@.  The
-- open-standard @.agents@ tree is on by default (like MiMo); project dirs
-- win over the home dir when two skills share a name.
module UI.Skills
  ( Skill(..)
  , parseSkill
  , skillsFromFiles
  , skillDirList
  , skillDirs
  , scanSkills
  ) where

import Control.Exception (IOException, catch)
import Data.List (sortOn)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, getHomeDirectory, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeBaseName, takeDirectory, takeFileName)

-- | One discoverable skill.
data Skill = Skill
  { skName        :: Text
  , skDescription :: Text
  , skPath        :: FilePath
  } deriving (Show, Eq)

-- | Parse one @SKILL.md@.  The name falls back to the directory (or file)
-- name when the frontmatter omits it; the description may be empty.
parseSkill :: FilePath -> Text -> Skill
parseSkill path body =
  Skill
    { skName = fromMaybe fallbackName (lookupField "name")
    , skDescription = fromMaybe "" (lookupField "description")
    , skPath = path
    }
  where
    fallbackName =
      let file = takeFileName path
      in T.pack $ if file == "SKILL.md" then takeBaseName (takeDirectory path)
                                        else takeBaseName path

    frontmatter = case T.lines body of
      (first : rest) | T.strip first == "---" ->
        let (block, _) = break ((== "---") . T.strip) rest
        in block
      _ -> []

    lookupField key =
      listToMaybe (mapMaybe (valueOf key) frontmatter)

    valueOf key line =
      let l = T.strip line
      in case T.stripPrefix (key <> ":") l of
           Just raw -> Just (clean raw)
           Nothing  -> Nothing

    clean = T.dropAround (\c -> c == '"' || c == '\'' || c == ' ') . T.strip

-- | Parse a batch of files, keeping the first skill per name and sorting by
-- name.  Order in the input is the precedence order.
skillsFromFiles :: [(FilePath, Text)] -> [Skill]
skillsFromFiles = sortOn skName . dedupe . map (uncurry parseSkill)
  where
    dedupe = foldl keep []
    keep acc s
      | any ((== skName s) . skName) acc = acc
      | otherwise                        = acc ++ [s]

-- | Candidate skill roots, highest precedence first.  @.agents@ is the open
-- standard and is on by default; @.trha@ keeps the scheduler's historical
-- location.  @TRHA_SKILLS_DIR@ comes last as an explicit extra root.
skillDirList :: FilePath -> FilePath -> Maybe FilePath -> [FilePath]
skillDirList cwd home extra =
  [ cwd </> ".agents" </> "skills"
  , cwd </> ".trha" </> "skills"
  , home </> ".agents" </> "skills"
  , home </> ".trha" </> "skills"
  ] ++ maybe [] pure extra

-- | 'skillDirList' with the real home directory and environment.
skillDirs :: FilePath -> IO [FilePath]
skillDirs cwd = do
  home <- getHomeDirectory
  extra <- lookupEnv "TRHA_SKILLS_DIR"
  pure (skillDirList cwd home extra)

-- | Read every @<name>/SKILL.md@ and @<name>.md@ under the given roots.
scanSkills :: [FilePath] -> IO [Skill]
scanSkills dirs = skillsFromFiles . concat <$> mapM scanOne dirs
  where
    scanOne dir = do
      entries <- listDirectory dir `catch` \(_ :: IOException) -> pure []
      concat <$> mapM (readEntry dir) entries

    readEntry dir name = do
      let nested = dir </> name </> "SKILL.md"
          flat = dir </> name
      nestedExists <- doesFileExist nested
      if nestedExists then one nested
        else if ".md" `T.isSuffixOf` T.pack name
               then do exists <- doesFileExist flat
                       if exists then one flat else pure []
               else pure []
      where
        one path = do
          body <- TIO.readFile path `catch` \(_ :: IOException) -> pure ""
          pure [ (path, body) ]
