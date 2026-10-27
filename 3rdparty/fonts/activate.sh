#!/usr/bin/env bash
# Point fontconfig at the fonts bundled in this directory, so a terminal (or
# any GUI app started from this shell) can render CJK / Tibetan / Yi / Myanmar
# / Thai without installing anything system-wide.
#
#   source 3rdparty/fonts/activate.sh
#   fc-match :lang=zh       # should report Noto Sans CJK SC
#
# fontconfig needs absolute <dir> paths, so the config is generated per run;
# the static fonts.conf next to this file is the reference version.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf="${TMPDIR:-/tmp}/trha-fonts.conf"

cat >"$conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>$here</dir>
  <cachedir>$here/.cache</cachedir>
  <match target="pattern">
    <test qual="any" name="family"><string>monospace</string></test>
    <edit name="family" mode="append" binding="same"><string>Noto Sans CJK SC</string></edit>
  </match>
  <match target="pattern">
    <test qual="any" name="family"><string>sans-serif</string></test>
    <edit name="family" mode="append" binding="same"><string>Noto Sans CJK SC</string></edit>
  </match>
</fontconfig>
EOF

export FONTCONFIG_FILE="$conf"
fc-cache -f >/dev/null 2>&1 || true
echo "FONTCONFIG_FILE=$FONTCONFIG_FILE"
fc-match :lang=zh | head -1
