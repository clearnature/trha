{-# LANGUAGE OverloadedStrings #-}

-- | 命令解析：把一行输入切成 @Command@。
--
-- 从 "UI.Commands.Registry" 拆出。解析是 Registry.Table 的**套壳**——
-- 命令名与解析动作都来自 'slashRegistry' 的 'scParse' 字段，本模块只保留
-- 三类不适合进数据表的特殊路径：
--
--   1. @/shell@ 保留原始参数文本（'T.words' 会吞掉引号内空格）；
--   2. @/mouse@ 账外隐藏命令（实现完整但未入册，见
--      docs/reference/dead-code-report-2026-11-12.md D3，处置待裁定）；
--   3. 用户自定义命令（@~/.trha/commands@）优先于内置表。
module UI.Commands.Registry.Parser
  ( parseCommand
  , parseCommandWith
  , parseCommandBase
  ) where

import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T

import UI.Commands.Registry.Types
import UI.Commands.Registry.Table (slashRegistry, SlashCommand(..))

parseCommand :: Text -> Command
parseCommand = parseCommandWith []

-- | Parse with user-defined command names (@~/.trha/commands@) recognised
-- first; the rest falls through to the built-in registry.
parseCommandWith :: [Text] -> Text -> Command
parseCommandWith custom input =
  case T.words (T.strip input) of
    (w : args)
      | Just name <- T.stripPrefix "/" w
      , name `elem` custom -> RunCustom name (T.unwords args)
    _ -> parseCommandBase input

-- | 表驱动解析：首词在注册表里就交给该行的 'scParse'。
parseCommandBase :: Text -> Command
-- @/shell@ keeps the raw argument text: re-splitting it with 'T.words' would
-- collapse the spaces inside quotes (e.g. @/shell echo "a  b"@).
parseCommandBase input
  | Just rest <- T.stripPrefix "/shell" (T.strip input)
  , T.null rest || " " `T.isPrefixOf` rest = RunShell (T.strip rest)
parseCommandBase input = case T.words (T.strip input) of
  [] -> SendMessage input
  (w : rest)
    -- 账外隐藏命令：/mouse 切换鼠标捕获，故意不进注册表（不进 help/picker）。
    | w == "/mouse" -> SetMouseCapture (case map T.toLower rest of
                                          ["on"]  -> Just True
                                          ["off"] -> Just False
                                          _       -> Nothing)
    | Just sc <- find ((== w) . scCommand) slashRegistry ->
        scParse sc (T.unwords rest)
    | "/" `T.isPrefixOf` w -> Unknown w
  _ -> SendMessage input
