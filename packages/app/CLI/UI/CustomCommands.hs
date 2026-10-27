{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | User-defined slash commands (@~/.trha/commands@, project
-- @./.trha/commands@).
--
-- One Markdown file per command: the file name is the command
-- (@review.md@ → @/review@), an optional leading @# heading@ is the
-- description, and the rest is the prompt.  @$ARGUMENTS@ in the body is
-- replaced with what the user typed after the command; without the
-- placeholder the arguments are appended as a new paragraph.
--
-- A malformed file is skipped, never fatal: a command directory is user
-- input, not part of the invariant.
module UI.CustomCommands
  ( CustomCommand(..)
  , parseCommandFile
  , renderCustomCommand
  , loadCustomCommands
  , loadCustomCommandsFrom
  ) where

import Control.Exception (IOException, catch)
import Data.Char (isAlphaNum)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
    ( doesDirectoryExist, getCurrentDirectory, listDirectory )
import System.FilePath ((</>), takeBaseName)

import Config.Settings (getConfigDir)

-- | One command file.
data CustomCommand = CustomCommand
  { ccName        :: Text   -- ^ @/name@ (file name without @.md@)
  , ccDescription :: Text   -- ^ first @# heading@, when present
  , ccTemplate    :: Text   -- ^ prompt body
  } deriving (Show, Eq)

-- | Parse @<name>.md@ content.  'Nothing' for an invalid name or an empty
-- body (an empty command would send an empty turn).
parseCommandFile :: Text -> Text -> Maybe CustomCommand
parseCommandFile name raw
  | not (validName name) = Nothing
  | T.null (T.strip body) = Nothing
  | otherwise = Just (CustomCommand name desc body)
  where
    (desc, body) = case T.lines raw of
      (l : rest) | "# " `T.isPrefixOf` T.stripStart l ->
        (T.strip (T.drop 2 (T.stripStart l)), T.unlines (dropWhile (T.null . T.strip) rest))
      _ -> ("", raw)
    validName n =
      not (T.null n)
        && T.all (\c -> isAlphaNum c || c == '-' || c == '_') n

-- | Expand @$ARGUMENTS@ (or append the arguments when there is no placeholder).
renderCustomCommand :: CustomCommand -> Text -> Text
renderCustomCommand cc args
  | "$ARGUMENTS" `T.isInfixOf` template = T.replace "$ARGUMENTS" (T.strip args) template
  | T.null (T.strip args) = template
  | otherwise = template <> "\n\n" <> T.strip args
  where
    template = T.strip (ccTemplate cc)

-- | @./.trha/commands@ then @~/.trha/commands@ (the user's definition wins on
-- a name clash).
customCommandDirs :: IO [FilePath]
customCommandDirs = do
  cwd <- getCurrentDirectory
  home <- getConfigDir
  pure [cwd </> ".trha" </> "commands", home </> "commands"]

loadCustomCommands :: IO [CustomCommand]
loadCustomCommands = customCommandDirs >>= loadCustomCommandsFrom

-- | Load from explicit directories; a later directory overrides an earlier
-- one by name (so the user's file wins over the project's).
loadCustomCommandsFrom :: [FilePath] -> IO [CustomCommand]
loadCustomCommandsFrom dirs = do
  found <- concat <$> mapM scan dirs
  pure (foldl replaceInPlace [] found)
  where
    -- a later definition overrides an earlier one but keeps its position,
    -- so the directory order still reads naturally
    replaceInPlace acc cc = case break ((== ccName cc) . ccName) acc of
      (before, _ : after) -> before ++ [cc] ++ after
      _                   -> acc ++ [cc]

    scan dir = do
      ok <- doesDirectoryExist dir
      if not ok then pure [] else do
        names <- sort . filter (T.isSuffixOf ".md" . T.pack)
               <$> (listDirectory dir `catch` \(_ :: IOException) -> pure [])
        concat <$> mapM (readOne dir) names

    readOne dir name = do
      body <- TIO.readFile (dir </> name) `catch` \(_ :: IOException) -> pure ""
      pure [ cc | Just cc <- [parseCommandFile (T.pack (takeBaseName name)) body] ]
