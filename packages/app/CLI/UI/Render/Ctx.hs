{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | /ctx 用量行的共享渲染——REPL 面（UI.Commands.Model）与 TUI 面
-- （UI.Brick.Slash.Model）同源，两个面不允许漂移出两种口径。
module UI.Render.Ctx
  ( renderCtxUsage
  , fmtTokens
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Bridge.Scheduler (ContextState(..))

-- | token 数带单位：≥1M 显式 M（一位小数），≥10k 用 k，其余原样。带符号。
fmtTokens :: Int -> Text
fmtTokens n = sign <> magnitude
  where
    a = abs n
    sign = if n < 0 then "-" else ""
    magnitude
      | a >= 1_000_000 = T.pack (show (a `div` 1_000_000))
                     <> "." <> T.pack (show ((a `mod` 1_000_000) `div` 100_000)) <> "M"
      | a >= 10_000    = T.pack (show (a `div` 1000)) <> "k"
      | otherwise      = T.pack (show n)

-- | 十格用量条。
ctxBar :: Int -> Text
ctxBar pct = T.pack (replicate filled '█' <> replicate (10 - filled) '░')
  where filled = min 10 (max 0 (pct `div` 10))

-- | 例：@[██░░░░░░░░] 43% · 214.3k/524.2k tokens · exact · msgs 42 · last: snip -38k@
renderCtxUsage :: ContextState -> Text
renderCtxUsage cs = T.unwords
  [ "[" <> ctxBar (csPercent cs) <> "]"
  , T.pack (show (csPercent cs)) <> "%"
  , "·"
  , fmtTokens (csPressure cs) <> "/" <> fmtTokens (csWindow cs) <> " tokens"
  , "·"
  , if csExact cs then "exact" else "~estimate"
  , "·"
  , "msgs " <> T.pack (show (csMessageCount cs))
  ]
  <> maybe ""
       (\trg -> " · last: " <> trg
           <> maybe "" (\st -> " " <> fmtTokens (- st)) (csSavedTokens cs))
       (csTrigger cs)
