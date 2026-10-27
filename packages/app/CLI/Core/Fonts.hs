{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Helpers for the bundled fonts (@3rdparty/fonts@).
--
-- A terminal renders glyphs itself; a program cannot swap the terminal's
-- font table.  What the project /can/ do natively is (a) ship the fonts,
-- (b) register them with the user's fontconfig so every terminal resolves
-- them, and (c) tell the user what a text console (TTY) would need instead.
module Core.Fonts
  ( fontsDir
  , fontsStatus
  , fontsActivate
  , fontsTty
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getCurrentDirectory
  , getHomeDirectory
  )
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

-- | Where the bundled fonts live.  Prefers @./3rdparty/fonts@ (running from a
-- checkout), which is how the repo ships them.
fontsDir :: IO FilePath
fontsDir = do
  cwd <- getCurrentDirectory
  let cand = cwd </> "3rdparty" </> "fonts"
  ok <- doesDirectoryExist cand
  pure (if ok then cand else cwd </> "3rdparty" </> "fonts")

-- | One-shot report: what the terminal resolves for Chinese, and what the
-- console is currently configured with.
fontsStatus :: IO [Text]
fontsStatus = do
  dir <- fontsDir
  (fc, _) <- run "fc-match" ["-f", "%{file}", ":lang=zh"] ""
  (face, _) <- run "grep"
    ["-hE", "^FONTFACE|^FONTSIZE", "/etc/default/console-setup"] ""
  haveFbterm <- installed "fbterm"
  haveOtf2bdf <- installed "otf2bdf"
  haveBdf2psf <- installed "bdf2psf"
  havePsf <- doesFileExist (dir </> "trha-cjk-16.psf")
  pure
    [ "fonts dir: " <> T.pack dir
    , "fc-match :lang=zh -> " <> T.strip (T.pack fc)
    , "console: " <> T.strip (T.pack face)
    , "bundled PSF: " <> (if havePsf then "yes (trha-cjk-16.psf)" else "no (run make-psf.py)")
    , "fbterm: " <> yn haveFbterm
        <> "  otf2bdf: " <> yn haveOtf2bdf
        <> "  bdf2psf: " <> yn haveBdf2psf
    , "hint: `trha fonts activate` registers the bundled fonts for this user"
    ]
  where
    yn b = if b then "yes" else "no" :: Text
    installed name = do
      (out, _) <- run "which" [name] ""
      pure (not (T.null (T.strip (T.pack out))))

-- | Register the bundled directory in @~/.config/fontconfig/fonts.conf@ so
-- every fontconfig-aware terminal/app finds it without sourcing a script.
fontsActivate :: IO (Either Text Text)
fontsActivate = do
  dir <- fontsDir
  home <- getHomeDirectory
  -- A conf.d drop-in, not fonts.conf itself: the user's own fontconfig
  -- entries stay untouched and `fonts activate` stays idempotent.
  let cfgDir = home </> ".config" </> "fontconfig" </> "conf.d"
      cfg = cfgDir </> "90-trha-fonts.conf"
  createDirectoryIfMissing True cfgDir
  TIO.writeFile cfg (renderConf dir)
  (_, err) <- run "fc-cache" ["-f"] ""
  let extra = if null err then "" else " (fc-cache: " <> T.pack err <> ")"
  pure (Right ("wrote " <> T.pack cfg <> extra))

renderConf :: FilePath -> Text
renderConf dir = T.unlines
  [ "<?xml version=\"1.0\"?>"
  , "<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">"
  , "<fontconfig>"
  , "  <dir>" <> T.pack dir <> "</dir>"
  , "  <match target=\"pattern\">"
  , "    <test qual=\"any\" name=\"family\"><string>monospace</string></test>"
  , "    <edit name=\"family\" mode=\"append\" binding=\"same\"><string>Noto Sans CJK SC</string></edit>"
  , "  </match>"
  , "</fontconfig>"
  ]

-- | What a Linux text console would need: it only loads PSF bitmaps.
fontsTty :: IO [Text]
fontsTty = do
  dir <- fontsDir
  pure
    [ "TTY 只认 PSF 位图字体（setfont），TTF 不能直接用，所以纯命令行下中文是方块。"
    , "A) fbterm（推荐，真实 TTF 渲染；已安装时直接可用）:"
    , "   trha fonts activate && fbterm -f \"Noto Sans CJK SC\""
    , "   退出 fbterm: Ctrl+Alt+E"
    , "B) 自带 PSF（零安装，fbterm 不可用时；23 167 字形）:"
    , "   sudo setfont " <> T.pack dir <> "/trha-cjk-16.psf -m 512"
    , "   覆盖：ASCII + 简体中文（SC 面）+ 藏文 + 彝文 + 缅甸文 + 泰文"
    , "   持久化：cp 到 /usr/share/consolefonts/，在 /etc/default/console-setup 设 FONT 后 setupcon"
    , "C) 重新生成 PSF（开发机，需要 Pillow）:"
    , "   python3 " <> T.pack dir <> "/make-psf.py"
    , "   注：otf2bdf + bdf2psf 无法处理 CJK 比例字体（实测 \"the width is not integer number\"），"
    , "       所以 PSF 由 Pillow 从 TTC 直接光栅化生成。"
    , "完整脚本: bash " <> T.pack dir <> "/tty-cjk.sh"
    ]

run :: FilePath -> [String] -> String -> IO (String, String)
run cmd args input = do
  r <- try (readProcessWithExitCode cmd args input)
  pure $ case r of
    Right (_, out, err) -> (out, err)
    Left (_ :: IOException) -> ("", "not available: " <> cmd)
