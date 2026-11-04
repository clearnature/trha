{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 状态栏：**文本层** + **装配层**。
--
-- 从 @UI.Brick@（4400 行）分批拆出。文本层把 'AppState' 映射成文本（模型标签、
-- @/status@ 摘要、价格表），是纯函数、可无终端单测；装配层 @drawStatus@ 只是把
-- 这些文本摆成两行 Widget，不含任何交互或事件处理。
--
-- 依赖方向：纯函数（UI.Render.Spans / UI.Render.Footer）← 本层 ← 交互。
-- 反向引用一律不允许（本模块不得 import UI.Brick）。
module UI.Brick.Draw.Status
  ( modelLabel
  , pricesOf
  , statusLine
  -- * 状态栏文本（drawStatus 的纯数据源）
  , statusSandboxTag
  , statusClock
  , statusModelLine
  , statusGitLine
  , statusPeak
  , statusStatsLine
  -- * 统计工具
  , statusCommas
  , statusShortK
  , statusPct
  , statusOneDec
  , statusUsable
  , statusCtxPct
  , statusTurnsSuffix
  -- * 状态栏装配（迁自 UI.Brick）
  , drawStatus
  , gitBranchText
  , gitStatText
  ) where

import Brick
import Brick.Widgets.Core
import Control.Exception (IOException, catch, try)
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)
import Data.Maybe (fromMaybe)
import UI.Brick.Status.Format
  ( statusCommas, statusCtxPct, statusOneDec, statusPct
  , statusShortK, statusTurnsSuffix, statusUsable )
import UI.Brick.Status.Shared (modelLabel, pricesOf)
import UI.Brick.Status.Stats (statusPeak, statusStatsLine)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Lens.Micro ((^.))
import Numeric (showFFloat)
import System.FilePath (takeFileName)

import Core.Types (SessionMode(..))
import UI.Dialog (SandboxSettings(..))
import UI.I18n (tr)
import UI.Render.Footer (branchFromHead, statusFitsOneRow, wrapStatusLine)
import UI.State (AppState(..), ResourceName(..))
import UI.TextWidth (takeCells)

import Core.TurnStats (Prices(..), hasPrices, isOffPeak, pricesForModel)
import Core.Types
  ( CLIConfig(..), balanceCurrency, balanceTotal, configMetrics, configPriceCached
  , configPriceInput, configPriceOutput, usageCompletionTokens, usagePromptTokens
  , usageTotalTokens )
import UI.Dialog (ssEnabled)
import UI.I18n (Lang, tr)
import UI.Render.Footer (parseMetrics)
import UI.State (AppState(..))
import UI.TimeStamp (clockWithZone)

-- | @provider/model@ 或裸模型名（没有选中 provider 时）。
statusLine :: AppState -> Text
statusLine st = T.unlines
  [ tr lang "Status:"
  , tr lang "  Session: " <> maybe (tr lang "none") T.pack (appSessionId st)
  , tr lang "  Model: " <> modelLabel st
  , "  " <> appStatus st
  ]
  where lang = appLang st
statusSandboxTag :: AppState -> Text
statusSandboxTag st =
  "SandBox:" <> (if ssEnabled (appSandbox st) then "enabled" else "disabled")

-- | 本地时钟；没有时间源时返回空串，状态栏就不渲染这一段。
statusClock :: AppState -> Text
statusClock st = case (appNow st, appTz st) of
  (Just t, Just tz) -> clockWithZone tz t
  _ -> ""

-- | 模型名 + 推理强度。
statusModelLine :: AppState -> Text
statusModelLine st = "模型 " <> modelLabel st <> "   强度 " <> appEffort st

-- | @目录@分支 [git 状态]@。
statusGitLine :: AppState -> Text
statusGitLine st =
  let ws = fromMaybe "" (lookup "workspace" (appMetrics st))
      dirName = T.pack (takeFileName (T.unpack ws))
      branch = fromMaybe "?" (lookup "git" (appMetrics st))
  in dirName <> "@" <> branch
       <> (if T.null (appGitStat st) then "" else "  " <> appGitStat st)

-- | 峰谷时段标签（DeepSeek 的低峰折扣）。


drawStatus :: AppState -> Widget ResourceName
drawStatus st = Widget Greedy Fixed $ do
  c <- getContext
  render (vBox (line1 (c ^. availWidthL) : secondRow (c ^. availWidthL)))
  where
    lang = appLang st
    -- 窄终端先牺牲常驻帮助文本：模型名与沙箱徽标比「Shift+Tab …」这类
    -- 看过就会的提示更值得占位（80 列下实测模型名会被整段挤掉）。
    line1 avail = padLeftRight 1 $ hBox (concat
      [ [ withAttr (attrName "error") (str (T.unpack modeTag))
        -- 这里原来是常量 " · ready"：appStatus 被各处设置（工具状态、
        -- 中断中、再按一次退出…）却从未真正显示出来。
        , withAttr (attrName "status")
            (str (T.unpack (" · " <> takeCells 48 (appStatus st))))
        ]
      , [ withAttr (attrName "timestamp") (str (T.unpack (" · " <> clockNow)))
        | not (T.null clockNow) ]
      , if avail >= 130
          then [ withAttr (attrName "timestamp")
                   (str (T.unpack (tr lang " · Shift+Tab read-only/ask/auto/YOLO/plan · Ctrl+Y YOLO")))
               , str "   "
               , withAttr (attrName (if ssEnabled (appSandbox st) then "status" else "error"))
                   (str (T.unpack sandboxTag)) ]
          else []
      , [ padLeft Max (withAttr (attrName "timestamp") (str (T.unpack modelLine))) ]
      ])
    line2 = padLeftRight 1 $ hBox
      [ withAttr (attrName "timestamp") (str (T.unpack gitLine))
      , padLeft Max (withAttr (attrName "timestamp") (str (T.unpack statsLine)))
      ]
    -- Second row: git summary on the left, metrics on the right.  Only when
    -- the two fit side by side — otherwise hBox clips the right end of the
    -- metrics (balance / cost / peak) with no way to read it.  On a narrow
    -- terminal each side gets its own rows, wrapped by display width.
    secondRow avail
      | statusFitsOneRow budget gitLine statsLine = [line2]
      | otherwise = map row (wrapStatusLine budget gitLine ++ wrapStatusLine budget statsLine)
      where
        budget = max 1 (avail - 2)
        row r = padLeftRight 1 $ timestampWidget $ str (T.unpack r)
    timestampWidget = withAttr (attrName "timestamp")
    modeTag = maybe "Read only" smLabel (appMode st)
    sandboxTag = statusSandboxTag st
    clockNow = statusClock st
    modelLine = statusModelLine st
    gitLine = statusGitLine st
    -- 统计段的实现在顶层 statusStatsLine（本批次迁出），此处不再保留副本。
    -- （成本 / 余额 / 缓存命中段同样在 statusStatsLine 里）
    statsLine = statusStatsLine st

--------------------------------------------------------------------------------
-- Event handling
--------------------------------------------------------------------------------


gitBranchText :: IO Text
gitBranchText = do
  cwd <- getCurrentDirectory
  (code, out, _) <- runGit ["-C", cwd, "symbolic-ref", "--short", "HEAD"]
  let branch = T.strip (T.pack out)
  if code == ExitSuccess && not (T.null branch)
    then return branch
    else do
      (code2, out2, _) <- runGit ["-C", cwd, "rev-parse", "--short", "HEAD"]
      let short = T.strip (T.pack out2)
      if code2 == ExitSuccess && not (T.null short)
        then return short
        else do
          mhead <- readMaybeFile ".git/HEAD"
          return $ case mhead >>= branchFromHead of
            Just b  -> b
            Nothing -> case mhead of
              Just hd -> T.take 7 (T.strip hd)
              Nothing -> "—"
  where
    runGit args =
      readProcessWithExitCode "git" args "" `catch` \(_ :: IOException) ->
        pure (ExitFailure 1, "", "")
    readMaybeFile fp = do
      r <- try (TIO.readFile fp) :: IO (Either IOException Text)
      return $ case r of
        Left _  -> Nothing
        Right t -> Just t

-- | `+N -M ?K` for the second status line (tracked diff + untracked files).
gitStatText :: IO Text
gitStatText = do
  cwd <- getCurrentDirectory
  (_, ns, _) <- runGit ["-C", cwd, "diff", "--numstat"]
  (_, st, _) <- runGit ["-C", cwd, "status", "--porcelain"]
  let rows = filter (not . T.null) (T.lines (T.pack ns))
      pairs = [ (a, d) | r <- rows
                       , let parts = T.splitOn "\t" r
                       , length parts >= 2
                       , let a = parts !! 0
                       , let d = parts !! 1
                       , a /= "-" ]
      adds = sum [ readI a | (a, _) <- pairs ]
      dels = sum [ readI d | (_, d) <- pairs ]
      -- Only "??" rows are untracked; counting every porcelain row (as this
      -- used to) reported modified files as untracked and inflated the
      -- second status row.
      untracked = length [ r | r <- T.lines (T.pack st), "??" `T.isPrefixOf` r ]
      diff = if adds == 0 && dels == 0 then "" else "+" <> T.pack (show adds) <> " -" <> T.pack (show dels)
      unt = if untracked > 0 then " ?" <> T.pack (show untracked) else ""
  pure (T.strip (diff <> "  " <> unt))
  where
    runGit args =
      readProcessWithExitCode "git" args "" `catch` \(_ :: IOException) ->
        pure (ExitSuccess, "", "")
    readI t = fromMaybe 0 (readMaybe (T.unpack t))

-- | settingsListMax 见 UI.Brick.Draw.Settings。

-- | One task glyph (sidebar and /todo share the vocabulary).
-- | todoGlyph 见 UI.Render.Spans。

-- | copyToClipboard 见 UI.Brick.Selection。

