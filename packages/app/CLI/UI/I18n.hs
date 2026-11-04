{-# LANGUAGE OverloadedStrings #-}

-- | Interface language support (i18n) for the trha shell.
--
-- Pure module -- no IO -- so translation lookups are unit-testable.
--
-- Design: every user-facing string stays in English as its canonical
-- key; rendering looks the key up through 't'.  When the active language
-- is 'Zh' and the key is in 'zhDict' the Chinese translation is returned,
-- otherwise the key itself (English) is the fallback.  This keeps
-- 'En' behaviour byte-identical to the pre-i18n shell and makes missing
-- translations degrade gracefully.
module UI.I18n
  ( Lang(..)
  , parseLang
  , langName
  , tr
  , zhDict
  , toTraditional
  ) where

import UI.I18n.Other (boDict, esDict, frDict, iiDict, myDict, ruDict, thDict)
import UI.I18n.Zh (zhDict)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as M

-- | Active interface language.
data Lang
  = Zh   -- ^ Simplified Chinese (default interface)
  | ZhHant -- ^ Traditional Chinese (zh-Hant)
  | Fr   -- ^ French
  | Es   -- ^ Spanish
  | Ru   -- ^ Russian
  | Th   -- ^ Thai
  | Bo   -- ^ Tibetan (support requested 2026-10-26; skeleton, needs native review)
  | Ii   -- ^ Nuosu Yi (same)
  | My   -- ^ Burmese (Myanmar)
  | En   -- ^ English
  deriving (Show, Eq, Ord, Bounded, Enum)

-- | Parse a language identifier (from CLI flag or settings file).
--
-- Tags follow BCP 47 with ISO 15924 script subtags for Chinese
-- (@zh-Hans@ / @zh-Hant@); no legacy region aliases are accepted — unknown
-- values fall back to 'En' so typos never crash the shell.
parseLang :: Text -> Lang
parseLang raw = case T.toLower (T.strip raw) of
  "zh-hans" -> Zh
  "zh-hans-cn" -> Zh
  "zh-hans-sg" -> Zh
  "zh-hant" -> ZhHant
  "fr"      -> Fr
  "es"      -> Es
  "ru"      -> Ru
  "th"      -> Th
  "en"      -> En
  "en-us"   -> En
  "en-gb"   -> En
  "fr-fr"   -> Fr
  "es-es"   -> Es
  "ru-ru"   -> Ru
  "th-th"   -> Th
  "bo"      -> Bo
  "bo-cn"   -> Bo
  "ii"      -> Ii
  "ii-cn"   -> Ii
  "my"      -> My
  "my-mm"   -> My
  _         -> En

-- | Short display name for a language.
langName :: Lang -> Text
langName Zh   = "zh-Hans"
langName ZhHant = "zh-Hant"
langName Fr   = "fr"
langName Es   = "es"
langName Ru   = "ru"
langName Th   = "th"
langName Bo   = "bo"
langName Ii   = "ii"
langName My   = "my"
langName En   = "en"

-- | Translate an English key into the active language.  Every non-English
-- dictionary is a skeleton: translated keys win, everything else falls back
-- to the canonical English (missing translations never break the shell).
tr :: Lang -> Text -> Text
tr En key = key
tr Zh key = M.findWithDefault key key zhDict
tr ZhHant key = toTraditional (M.findWithDefault key key zhDict)
tr Fr key = M.findWithDefault key key frDict
tr Es key = M.findWithDefault key key esDict
tr Ru key = M.findWithDefault key key ruDict
tr Th key = M.findWithDefault key key thDict
tr Bo key = M.findWithDefault key key boDict
tr Ii key = M.findWithDefault key key iiDict
tr My key = M.findWithDefault key key myDict

-- | Simplified → Traditional conversion for the interface vocabulary.
-- Traditional Chinese shares the dictionary; only the glyphs differ, so a
-- character map keeps one source of truth instead of a second full table.
toTraditional :: Text -> Text
toTraditional = T.map (\c -> M.findWithDefault c c hantChars)

hantChars :: M.Map Char Char
hantChars = M.fromList
  [ ('设','設'), ('话','話'), ('会','會'), ('项','項'), ('开','開'), ('关','關')
  , ('发','發'), ('现','現'), ('显','顯'), ('这','這'), ('个','個'), ('为','為'), ('从','從')
  , ('对','對'), ('时','時'), ('间','間'), ('问','問'), ('题','題'), ('读','讀')
  , ('写','寫'), ('删','刪'), ('选','選'), ('择','擇'), ('状','狀'), ('态','態')
  , ('连','連'), ('错','錯'), ('误','誤'), ('输','輸'), ('总','總'), ('计','計')
  , ('历','歷'), ('帮','幫'), ('颜','顏'), ('体','體'), ('语','語'), ('简','簡')
  , ('当','當'), ('标','標'), ('签','籤'), ('页','頁'), ('载','載'), ('导','導')
  , ('缓','緩'), ('压','壓'), ('缩','縮'), ('占','佔'), ('应','應'), ('务','務')
  , ('远','遠'), ('权','權'), ('网','網'), ('络','絡'), ('机','機'), ('记','記')
  , ('忆','憶'), ('调','調'), ('试','試'), ('诊','診'), ('断','斷'), ('观','觀')
  , ('键','鍵'), ('储','儲'), ('径','徑'), ('於','於'), ('检','檢'), ('声','聲')
  , ('强','強'), ('认','認'), ('余','餘'), ('询','詢'), ('动','動'), ('划','劃')
  , ('审','審'), ('绝','絕'), ('过','過'), ('弃','棄'), ('复','復'), ('暂','暫')
  , ('没','沒'), ('败','敗'), ('与','與'), ('们','們'), ('说','說'), ('让','讓')
  , ('给','給'), ('万','萬'), ('亿','億'), ('点','點'), ('线','線'), ('图','圖')
  , ('数','數'), ('据','據'), ('库','庫'), ('称','稱'), ('铁','鐵'), ('华','華')
  , ('国','國'), ('学','學'), ('习','習'), ('书','書'), ('写','寫'), ('读','讀')
  , ('门','門'), ('闭','閉'), ('户','戶'), ('单','單'), ('双','雙'), ('击','擊')
  , ('打','打'), ('断','斷'), ('续','續'), ('断','斷'), ('变','變'), ('化','化')
  , ('运','運'), ('行','行'), ('监','監'), ('测','測'), ('录','錄'), ('影','影')
  , ('响','響'), ('质','質'), ('量','量'), ('优','優'), ('级','級'), ('别','別')
  , ('权','權'), ('益','益'), ('规','規'), ('则','則'), ('删','刪'), ('改','改')
  , ('增','增'), ('查','查'), ('找','找'), ('搜','搜'), ('索','索'), ('引','引')
  , ('擎','擎'), ('页','頁'), ('面','面'), ('板','板'), ('区','區'), ('域','域')
  , ('栏','欄'), ('档','檔'), ('案','案'), ('夹','夾'), ('题','題'), ('目','目')
  , ('录','錄'), ('级','級'), ('联','聯'), ('系','系'), ('绑','綁'), ('定','定')
  , ('认','認'), ('证','證'), ('凭','憑'), ('据','據'), ('密','密'), ('钥','鑰')
  , ('匙','匙'), ('令','令'), ('牌','牌'), ('权','權'), ('限','限'), ('桶','桶')
  , ('队','隊'), ('列','列'), ('排','排'), ('程','程'), ('序','序'), ('员','員')
  , ('组','組'), ('装','裝'), ('配','配'), ('置','置'), ('启','啟'), ('停','停')
  , ('用','用'), ('禁','禁'), ('卸','卸'), ('载','載')
  -- 会话/状态词（此前缺失，ZhHant 会渲染成混合简繁）
  , ('绪','緒'), ('细','細'), ('统','統'), ('转','轉'), ('换','換')
  , ('志','誌'), ('详','詳')
  ]

-- | English -> Simplified Chinese dictionary.  Keys are the canonical
-- English strings used by the shell (command descriptions, status text,
-- hints, feedback messages).
