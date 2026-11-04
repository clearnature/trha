{-# LANGUAGE OverloadedStrings #-}

-- | 命令面板与供应商向导的渲染。
--
-- 从 @UI.Brick@ 拆出的批次 2b（对话框家族的轻量成员）。这里只做 Widget 装配：
-- 条目筛选与滚动窗口来自 UI.Render.Picker，向导字段来自 UI.State。
--
-- @drawDialog@（310 行、十余种 'Dialog' 构造子）与 @drawSettingsPanel@ 留待
-- 批次 2c——它们体量大，需要单独一轮。
module UI.Brick.Draw.Dialog
  ( drawDialog
  , dialogRow
  , dialogCountdown
  , dialogApprovalLabel
  , dialogConfirmLabel
  , dialogRows
  , drawPalette
  , drawWizard
  , wizardSummary
  ) where

import Brick
  ( Widget, attrName, emptyWidget, fill, hBox, hLimit, padLeftRight, str, vBox
  , withAttr )
import Brick.Widgets.Border (borderWithLabel)
import Brick.Widgets.Core (strWrap)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Core.SessionSummary (SessionSummary(..))
import Core.Types (AgentEntry(..), ModelInfo(..), ProviderInfo(..), configAskTimeout)
import UI.Dialog
  ( ApprovalOption(..), Dialog(..), SandboxSettings(..), approvalOptions
  , dialogCommandsItems, dialogCommandsSelected, dialogCount, dialogEditable
  , dialogModelsItems, dialogQuery, dialogSelected, dialogSessionsItems
  , dialogSkillsItems, dialogTitle )
import UI.I18n (langName, tr)
import UI.Interaction (askCountdownText)
import UI.ModelPrefs (isFavorite)
import UI.ProviderPresets (Preset(..))
import UI.Render.Picker (PickerItem(..), isSection, windowRange)
import UI.Skills (Skill(..))
import UI.State (AppState(..), ProviderWizard(..), ResourceName(..), wizardPrompts)
import UI.TextWidth (takeCells)
import UI.Theme (Theme(..))

-- | 命令面板：输入 @/@ 后就地展开的列表（MiMo 形态：在提示上方，随输入
-- 过滤，不是抢焦点的居中弹窗）。
drawPalette :: Dialog -> Widget ResourceName
drawPalette d =
  withAttr (attrName "tool") $
    hLimit 66 $
      borderWithLabel (withAttr (attrName "title") $ str " Commands ") $
        vBox $
          if null items
            then [ padLeftRight 1 $ withAttr (attrName "timestamp") $
                     str " no matching command" ]
            else [ let selected = idx == sel
                       marker = if selected then "▸ " else "  "
                       attr = if selected then "tool" else "timestamp"
                   in if isSection it
                        then padLeftRight 1 $ withAttr (attrName "timestamp") $
                               str (" " <> T.unpack (piLabel it))
                        else padLeftRight 1 $ hBox
                        [ withAttr (attrName attr) $ str marker
                        , withAttr (attrName "title") $ str (T.unpack (piId it))
                        , withAttr (attrName "timestamp") $ str "  "
                        , withAttr (attrName "timestamp") $
                            str (T.unpack (takeCells 44 (piDesc it))) ]
                 | (idx, it) <- zip [start ..]
                                   (take (end + 1) (drop start items)) ]
  where
    items = dialogCommandsItems d
    sel = dialogCommandsSelected d
    -- 30 行高的可视窗口，随光标滚动。
    (start, end) = windowRange (length items) sel 30

-- | 供应商向导卡片：进度、当前提示、已收集内容。
drawWizard :: ProviderWizard -> Widget ResourceName
drawWizard w =
  withAttr (attrName "border") $
    hLimit 72 $
      borderWithLabel (withAttr (attrName "title") $
        str (" Provider " <> show (pwStep w + 1) <> "/6 ")) $
        vBox
          [ padLeftRight 1 $ withAttr (attrName "title") $
              str (T.unpack (wizardPrompts !! pwStep w))
          , padLeftRight 1 $ withAttr (attrName "timestamp") $
              str (T.unpack (wizardSummary w))
          ]

wizardSummary :: ProviderWizard -> Text
wizardSummary w = T.intercalate "  ·  "
  [ "name " <> shown (pwName w)
  , "kind " <> shown (pwKind w)
  , "url " <> shown (pwBaseUrl w)
  , "models " <> shown (pwModels w)
  ]
  where shown t = if T.null (T.strip t) then "—" else T.strip t

dialogRow :: Int -> Int -> Widget ResourceName -> Widget ResourceName -> Widget ResourceName
dialogRow idx cur label detail =
  padLeftRight 1 $ hBox
    [ withAttr markerAttr $ str marker
    , str " "
    , withAttr (attrName "title") label
    , withAttr (attrName "timestamp") (str "  ")
    , withAttr (attrName "timestamp") detail
    ]
  where
    marker | idx == cur = "▸ "
           | otherwise  = "  "
    markerAttr | idx == cur = attrName "tool"
               | otherwise  = attrName "timestamp"

-- | 审批倒计时行（纯逻辑在 UI.Interaction.askCountdownText）。
dialogCountdown :: AppState -> Text
dialogCountdown st =
  fromMaybe ""
    (askCountdownText (configAskTimeout (appEffCfg st)) (appAskAt st) (appNow st))

-- | 审批选项的标签。
dialogApprovalLabel :: ApprovalOption -> Text
dialogApprovalLabel opt = case opt of
  ApprovalOnce   -> "Allow once"
  ApprovalAlways -> "Allow always"
  ApprovalReject -> "Reject"

-- | 确认对话框的两个选项。
dialogConfirmLabel :: Int -> Text
dialogConfirmLabel i = case i of
  0 -> "Yes, allow always"
  _ -> "No, back"

-- | 对话框主体行：13 个构造子的分派。
--
-- 窗口位置由本函数自己算（@windowRange n sel 30@），调用方只需给状态与对话框。
dialogRows :: AppState -> Dialog -> [Widget ResourceName]
dialogRows st d = case d of
  DialogApproval msg name args asel ->
    let sel' = if n > 0 then min asel (n - 1) else 0
    in [ padLeftRight 1 $ withAttr (attrName "error") $
           strWrap ("△ " ++ T.unpack msg)
       ] <>
       [ dialogRow idx sel' (str (T.unpack (tr lang (dialogApprovalLabel opt)))) (str "")
       | (idx, opt) <- zip [0 ..] (approvalOptions name args) ]
       <> [ padLeftRight 1 $ withAttr (attrName "status") $
              str (T.unpack (dialogCountdown st))
          | not (T.null (dialogCountdown st)) ]
  DialogConfirm msg _ ->
    [ padLeftRight 1 $ strWrap (T.unpack msg) ] <>
    [ dialogRow idx sel (str (T.unpack (tr lang (dialogConfirmLabel idx)))) (str "")
    | idx <- [0 .. 1 :: Int] ]
  DialogModels _ _ _ ->
    [ dialogRow idx sel
        (str ((if isFavorite (modelName it) (appModelPrefs st) then "★ " else "  ")
              ++ T.unpack (modelName it)))
        (str ("ctx " ++ show (modelContextSize it)))
    | (idx, it) <- zip [start ..] (drop start (take (end + 1) (dialogModelsItems d))) ]
  DialogSessions _ _ _ ->
    [ dialogRow idx sel (str (T.unpack (ssTitle it)))
                  (str (ssId it ++ maybe "" (\tok -> "  " ++ show tok ++ " tok") (ssUsage it)))
    | (idx, it) <- zip [start ..] (drop start (take (end + 1) (dialogSessionsItems d))) ]
  DialogCommands{} ->
    [ dialogRow idx sel (str (T.unpack (piId it)))
                  (str (T.unpack (takeCells 44 (piDesc it))))
    | (idx, it) <- zip [start ..] (drop start (take (end + 1) (dialogCommandsItems d))) ]
  DialogPresets ps _ ->
    [ padLeftRight 1 $ withAttr (attrName "timestamp") $ str "Popular" ]
    ++ [ dialogRow idx sel (str (T.unpack (preName p)))
                  (str (T.unpack (preKind p <> " · " <> preBaseUrl p)))
         | (idx, p) <- zip [0 ..] ps, prePopular p ]
    ++ [ padLeftRight 1 $ withAttr (attrName "timestamp") $ str "Other" ]
    ++ [ dialogRow idx sel (str (T.unpack (preName p)))
                  (str (T.unpack (preKind p <> " · " <> preBaseUrl p)))
         | (idx, p) <- zip [0 ..] ps, not (prePopular p) ]
    ++ [ padLeftRight 1 $ withAttr (attrName "timestamp") $
           str "enter choose · esc cancel" ]
  DialogProviders ps _ ->
    if null ps
      then [ padLeftRight 1 $ withAttr (attrName "timestamp") $
               str " no providers (configure ~/.trha/providers.json)" ]
      else [ dialogRow idx sel (str (T.unpack (piName p)))
                    (str (T.unpack (piKind p <> " · " <> piDefault p
                                    <> (if piInUse p then " · in use" else ""))))
           | (idx, p) <- zip [start ..] (drop start (take (end + 1) ps)) ]
           ++ [ padLeftRight 1 $ withAttr (attrName "timestamp") $
                  str "a add · e edit · r re-probe · enter select" ]
  DialogSkills _ _ _ ->
    let its = dialogSkillsItems d
    in if null its
      then [ padLeftRight 1 $ withAttr (attrName "timestamp") $
               str " no skills (put SKILL.md under .agents/skills or .trha/skills)" ]
      else [ dialogRow idx sel (str (T.unpack (skName it)))
                    (str (T.unpack (takeCells 44 (skDescription it))))
           | (idx, it) <- zip [start ..] (drop start (take (end + 1) its)) ]
  DialogAgents as _ ->
    if null as
      then [ padLeftRight 1 $ withAttr (attrName "timestamp") $
               str " no agents (no subagent sessions)" ]
      else [ dialogRow idx sel (str (T.unpack (aeId it)))
                    (str (maybe "root" (\p -> "parent " <> T.unpack p) (aeParent it)))
           | (idx, it) <- zip [start ..] (drop start (take (end + 1) as)) ]
  DialogThemes ts _ ->
    [ dialogRow idx sel (str (T.unpack (themeName it)))
                  (str (if themeName it == themeName (appTheme st) then "current" else ""))
    | (idx, it) <- zip [start ..] (drop start (take (end + 1) ts)) ]
  DialogLanguages ls _ ->
    [ dialogRow idx sel (str (T.unpack (langName it)))
                  (str (if it == appLang st then "current" else ""))
    | (idx, it) <- zip [start ..] (drop start (take (end + 1) ls)) ]
  DialogSandbox ss _ ->
    [ dialogRow 0 sel (str (T.unpack ("SandBox: " <> (if ssEnabled ss then "enabled" else "disabled")))) (str "")
    , dialogRow 1 sel (str (T.unpack ("Policy: " <> ssPolicy ss))) (str "read-only | workspace-write")
    , dialogRow 2 sel (str (T.unpack ("Network: " <> (if ssNetwork ss then "enabled" else "disabled")))) (str "")
    , dialogRow 3 sel (str (T.unpack ("Scratch: " <> ssScratch ss))) (str "")
    , padLeftRight 1 $ withAttr (attrName "timestamp") $
        str "enter toggle · esc close"
    ]
  where
    lang = appLang st
    sel = dialogSelected d
    n = dialogCount d
    (start, end) = windowRange n sel 30

drawDialog :: AppState -> Dialog -> Widget ResourceName
drawDialog st d =
  withAttr (attrName "border") $
    borderWithLabel (withAttr (attrName "title") $ str (T.unpack title)) $
      vBox (rows ++ [queryRow])
  where
    lang = appLang st
    isEditable = dialogEditable d
    title = dialogTitle lang d
    sel = dialogSelected d
    n = dialogCount d
    -- 30 rows for every dialog, including the skills overlay.
    (start, end) = windowRange n sel 30
    rows = dialogRows st d

    -- 行渲染、审批标签、倒计时都已在顶层（dialogRow / dialogApprovalLabel /
    -- dialogConfirmLabel / dialogCountdown）。

    queryRow = case d of
      DialogCommands _ q _ -> padLeftRight 1 $ hBox
        [ withAttr (attrName "input") $ str ("> " ++ T.unpack q)
        , withAttr (attrName "status") $ str (T.unpack (tr lang "   ↑/↓ move · Enter run · Esc close"))
        ]
      DialogSkills _ q _ -> padLeftRight 1 $ hBox
        [ withAttr (attrName "input") $ str ("> " ++ T.unpack q)
        , withAttr (attrName "status") $ str (T.unpack (tr lang "   ↑/↓ move · Enter open · Esc close"))
        ]
      -- 其余对话框没有查询行，但操作提示同样要可见：审批/确认是
      -- 「选择」，模型/会话/主题等是「打开」。
      DialogApproval{}  -> hintRow "↑/↓ · Tab move · Enter choose · Esc close"
      DialogConfirm{}   -> hintRow "↑/↓ · Tab move · Enter choose · Esc close"
      DialogModels{}    -> idxHintRow "↑/↓ · Tab move · Enter open · Esc close"
      DialogSessions{}  -> idxHintRow "↑/↓ · Tab move · Enter open · Esc close"
      DialogThemes{}    -> hintRow "↑/↓ · Tab move · Enter open · Esc close"
      DialogLanguages{} -> hintRow "↑/↓ · Tab move · Enter open · Esc close"
      DialogAgents{}    -> hintRow "↑/↓ · Tab move · Enter open · Esc close"
      DialogPresets{}   -> hintRow "↑/↓ · Tab move · Enter open · Esc close"
      DialogProviders{} -> hintRow "↑/↓ · Tab move · Enter open · Esc close"
      DialogSandbox{}   -> hintRow "↑/↓ · Tab move · Enter open · Esc close"
      _ -> emptyWidget
    hintRow t = padLeftRight 1 $ withAttr (attrName "status") $ str (T.unpack (tr lang t))
    -- 可过滤的列表：查询行 + 提示（输入即过滤，回车打开）。
    idxHintRow t = padLeftRight 1 $ hBox
      [ withAttr (attrName "input") $ str ("> " ++ T.unpack (dialogQuery d))
      , withAttr (attrName "status") $ str ("   " ++ T.unpack (tr lang t))
      ]
    -- 查询串已由顶层 dialogQuery 统一提供。
