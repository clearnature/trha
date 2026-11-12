{-# LANGUAGE OverloadedStrings #-}

-- | 对话框的选择态：标题、选中项、是否可编辑、查询串、条目数、移动选择，
-- 以及三个列表过滤函数（skills / models / sessions）。
--
-- 过滤函数放在这里而不是 Editing：'dialogCount' 需要 'filterSkills'，
-- 若过滤留在家编辑模块就会 Selection ↔ Editing 成环。
module UI.Dialog.Selection
  ( dialogTitle, dialogSelected, dialogEditable, dialogQuery
  , dialogCount, dialogMoveSel
  , filterSkills, filterModels, filterSessions
  , approvalOptions, isDestructiveShell
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Core.SessionSummary (SessionSummary(..))
import Core.Types (ModelInfo(..))
import UI.I18n (Lang, tr)
import UI.Skills (Skill(..))

import UI.Render.Picker (filterItems, moveSelection, moveSelectionSkipping)
import UI.Dialog.Types (ApprovalOption(..), Dialog(..))

dialogTitle :: Lang -> Dialog -> Text
dialogTitle lang d = case d of
  DialogModels{}     -> tr lang " Models "
  DialogSessions{}   -> tr lang " Sessions "
  DialogCommands{}   -> tr lang " Commands "
  DialogProviders{}  -> tr lang " Providers "
  DialogPresets{}    -> tr lang " Providers "
  DialogSkills{}     -> tr lang " Skills "
  DialogAgents{}     -> tr lang " Agents "
  DialogThemes{}     -> tr lang " Themes "
  DialogLanguages{}  -> tr lang " Languages "
  DialogApproval{}   -> tr lang " Approval "
  DialogConfirm{}    -> tr lang " Confirm "
  DialogSandbox{}    -> tr lang " SandBox "
  DialogPick{}       -> tr lang " Todos "
  DialogPick t _ _ _ -> t

-- | 当前选中索引（同样必须覆盖全部构造子）。

dialogSelected :: Dialog -> Int
dialogSelected d = case d of
  DialogModels _ _ s -> s
  DialogSessions _ _ s -> s
  DialogCommands _ _ s -> s
  DialogProviders _ s -> s
  DialogPresets _ s -> s
  DialogSkills _ _ s -> s
  DialogAgents _ s -> s
  DialogThemes _ s -> s
  DialogLanguages _ s -> s
  DialogApproval _ _ _ s -> s
  DialogConfirm _ s -> s
  DialogSandbox _ s -> s
  DialogPick _ _ _ s -> s
  DialogTodos _ s    -> s

-- | 只有命令与技能面板接受字符输入（其余面板的字符键被丢弃）。

dialogEditable :: Dialog -> Bool
dialogEditable d = case d of
  DialogCommands{} -> True
  DialogSkills{}   -> True
  _                -> False

-- | 列表过滤用的查询串；不可过滤的面板返回空。

dialogQuery :: Dialog -> Text
dialogQuery d = case d of
  DialogModels _ q _ -> q
  DialogSessions _ q _ -> q
  DialogCommands _ q _ -> q
  DialogSkills _ q _ -> q
  _ -> ""

dialogCount :: Dialog -> Int
dialogCount (DialogModels ms q _)    = length (filterModels q ms)
dialogCount (DialogSessions ss q _)  = length (filterSessions q ss)
dialogCount (DialogCommands all0 q _) = length (filterItems q all0)
dialogCount (DialogProviders ps _)   = length ps
dialogCount (DialogPresets ps _)     = length ps
dialogCount (DialogSkills ss q _)    = length (filterSkills q ss)
dialogCount (DialogAgents as _)      = length as
dialogCount (DialogThemes ts _)      = length ts
dialogCount (DialogLanguages ls _)   = length ls
dialogCount (DialogApproval _ name args _) = length (approvalOptions name args)
dialogCount (DialogConfirm _ _)      = 2  -- yes / no
dialogCount (DialogSandbox _ _)      = 4  -- enabled / policy / network / scratch
dialogCount (DialogPick _ items _ _) = length items
dialogCount (DialogTodos ts _)       = length ts

-- | MiMo parity: destructive shell commands get no "always" option — a
-- permanent allow on @rm -rf@ is not a mistake the UI should make easy.
-- Everything else gets the full three-way choice.

dialogMoveSel :: Int -> Dialog -> Dialog
dialogMoveSel delta d = case d of
  DialogModels ms q s    -> DialogModels ms q (mv (dialogCount d) s)
  DialogSessions ss q s  -> DialogSessions ss q (mv (dialogCount d) s)
  DialogCommands all0 q s -> DialogCommands all0 q (moveSelectionSkipping delta s (filterItems q all0))
  DialogProviders ps s     -> DialogProviders ps (mv (dialogCount d) s)
  DialogPresets ps s       -> DialogPresets ps (mv (dialogCount d) s)
  DialogSkills ss q s      -> DialogSkills ss q (mv (dialogCount d) s)
  DialogAgents as s        -> DialogAgents as (mv (dialogCount d) s)
  DialogThemes ts s        -> DialogThemes ts (mv (dialogCount d) s)
  DialogLanguages ls s     -> DialogLanguages ls (mv (dialogCount d) s)
  DialogApproval m t a s  -> DialogApproval m t a (mv (dialogCount d) s)
  DialogConfirm m s       -> DialogConfirm m (mv (dialogCount d) s)
  DialogSandbox ss s      -> DialogSandbox ss (mv (dialogCount d) s)
  DialogPick t items act s -> DialogPick t items act (mv (dialogCount d) s)
  DialogTodos ts s        -> DialogTodos ts (mv (dialogCount d) s)
  where
    mv n s = moveSelection delta s n

-- | Append a character to the command query, re-filter the registry and
-- reset the selection.
-- | Skills filtered by a case-insensitive substring match on name/description.

filterSkills :: Text -> [Skill] -> [Skill]
filterSkills q ss
  | T.null (T.strip q) = ss
  | otherwise = filter matches ss
  where
    needle = T.toLower (T.strip q)
    matches sk = needle `T.isInfixOf` T.toLower (skName sk)
              || needle `T.isInfixOf` T.toLower (skDescription sk)

-- | 模型按名字过滤（不区分大小写的子串）。

filterModels :: Text -> [ModelInfo] -> [ModelInfo]
filterModels q ms
  | T.null (T.strip q) = ms
  | otherwise = filter (matches . modelName) ms
  where
    needle = T.toLower (T.strip q)
    matches name = needle `T.isInfixOf` T.toLower name

-- | 会话按 id 或标题过滤——列表一长，靠 ↑↓ 逐个翻不现实。

filterSessions :: Text -> [SessionSummary] -> [SessionSummary]
filterSessions q ss
  | T.null (T.strip q) = ss
  | otherwise = filter matches ss
  where
    needle = T.toLower (T.strip q)
    matches s = needle `T.isInfixOf` T.toLower (T.pack (ssId s))
             || needle `T.isInfixOf` T.toLower (ssTitle s)

approvalOptions :: String -> [Text] -> [ApprovalOption]
approvalOptions name args
  | isDestructiveShell name args = [ApprovalOnce, ApprovalReject]
  | otherwise = [ApprovalOnce, ApprovalAlways, ApprovalReject]

-- | Whether a shell tool call can delete data, judged from the tool name
-- and its first argument (the command line).  Deliberately conservative:
-- a false positive only costs one extra prompt.

isDestructiveShell :: String -> [Text] -> Bool
isDestructiveShell name args
  | name `notElem` shellTools = False
  | otherwise = case args of
      (cmd : _) -> destructive cmd
      []        -> False
  where
    shellTools = ["bash", "shell", "run_shell"]
    destructive cmd =
      let toks = dropWhile isPrefix (T.words (T.strip cmd))
      in case toks of
           (verb : rest) -> verb' verb `elem` destructiveVerbs
                            || (verb' verb == "git" && isDestructiveGit rest)
           [] -> False
    isPrefix t = t `elem` ["sudo", "doas", "env"] || "=" `T.isInfixOf` t
    verb' = T.toLower . T.takeWhile (/= '/')
    destructiveVerbs =
      [ "rm", "rmdir", "del", "erase", "format", "mkfs"
      , "dd", "shred", "truncate", "mv" ]
    isDestructiveGit (sub : more) = case T.toLower sub of
      "clean" -> True
      "reset" -> "--hard" `elem` more
      _       -> False
    isDestructiveGit [] = False

-- | Move the top dialog's selection by @delta@ (clamped; a no-op on
-- empty lists).
