#!/usr/bin/env bash
# CJK on a Linux text console (TTY, no X/Wayland).
#
# A TTY renders PSF bitmap fonts via setfont and cannot use TrueType directly,
# which is why Ubuntu 26's console shows 方块 (tofu) for CJK.  Two ways out,
# both driven by the fonts bundled next to this script:
#
#   A. fbterm  (recommended) — a framebuffer terminal that uses FreeType +
#      fontconfig, so NotoSansCJK in this directory renders directly.
#   B. PSF     (native TTY) — convert the TTC to BDF, then bdf2psf, setfont.
#
# Run with no arguments to see what this host already has.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
have() { command -v "$1" >/dev/null 2>&1 && echo "yes" || echo "no"; }

echo "fonts dir: $here"
echo "fbterm:    $(have fbterm)   (apt install fbterm)"
echo "otf2bdf:   $(have otf2bdf)  (apt install otf2bdf)"
echo "bdf2psf:   $(have bdf2psf)  (apt install bdf2psf)"
echo "console:   $(grep -hE '^FONTFACE|^FONTSIZE' /etc/default/console-setup 2>/dev/null | tr '\n' ' ')"
echo
cat <<'EOF'
A) fbterm (recommended when installed — real TTF rendering):

   source $here/activate.sh
   fbterm -f "Noto Sans CJK SC"
   # inside fbterm: run trha / trha serve; exit with Ctrl+Alt+E

B) zero-install fallback: the bundled PSF; setfont ships with Ubuntu:

   sudo setfont $here/trha-cjk-16.psf -m 512
   # persist: gzip -c trha-cjk-16.psf > trha-cjk-16.psf.gz
   #          sudo cp trha-cjk-16.psf.gz /usr/share/consolefonts/
   #          FONT="trha-cjk-16.psf.gz" in /etc/default/console-setup; sudo setupcon

C) regenerate the PSF (dev machine, needs Pillow):

   python3 $here/make-psf.py
   # note: otf2bdf + bdf2psf cannot convert CJK proportional fonts
   #       ("the width is not integer number"), so Pillow rasterises the TTC.

D) SSH / a terminal emulator — the font lives on the *client*; see README.md.
EOF
