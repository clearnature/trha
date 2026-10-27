{-# LANGUAGE OverloadedStrings #-}

-- | Clock formatting for the TUI (one place, so every time string carries a
-- zone identifier).
--
-- Local times read @07:31:12 CST@; UTC times read @23:31:12 UTC@.  The
-- abbreviation comes from the 'TimeZone' name (glibc gives @CST@ for
-- @Asia/Shanghai@); a fixed-offset zone without a name falls back to
-- @UTC+0800@.
module UI.TimeStamp
  ( clockWithZone
  , utcClock
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
  ( TimeZone, UTCTime, defaultTimeLocale, formatTime, utcToZonedTime )

-- | @07:31:12 CST@ in the given zone.
clockWithZone :: TimeZone -> UTCTime -> Text
clockWithZone tz t =
  let zt = utcToZonedTime tz t
      clock = T.pack (formatTime defaultTimeLocale "%H:%M:%S" zt)
      name = T.strip (T.pack (formatTime defaultTimeLocale "%Z" zt))
      -- glibc renders an unnamed zone as @+0800@ rather than an empty name;
      -- both that and an empty name mean "no abbreviation".
      isOffset = not (T.null name)
                 && (T.head name == '+' || T.head name == '-')
      -- Render @UTC+08:00@ instead of a dangling @+0800@.
      raw = T.pack (formatTime defaultTimeLocale "%z" zt)
      fallback =
        if T.length raw == 5
          then "UTC" <> T.take 3 raw <> ":" <> T.drop 3 raw
          else "UTC" <> raw
  in clock <> " " <> (if T.null name || isOffset then fallback else name)

-- | @23:31:12 UTC@ for a UTC instant.
utcClock :: UTCTime -> Text
utcClock t = T.pack (formatTime defaultTimeLocale "%H:%M:%S UTC" t)
