#!/usr/bin/env python3
"""Pre-render a 16x16 PSF2 console font from the bundled Noto fonts.

The Linux text console only loads PSF bitmaps (setfont), never TrueType.  This
script bakes the supported scripts into `trha-cjk-16.psf` so a user needs *no*
extra software: `setfont` ships with console-setup on Ubuntu.

CJK uses the **SC face** (index 2 of the TTC); Tibetan / Yi / Myanmar / Thai
come from their own bundled faces.  Complex scripts are rasterised as isolated
glyphs here (no shaping), so 16 px output is legible but not typeset.

    python3 3rdparty/fonts/make-psf.py
    sudo setfont 3rdparty/fonts/trha-cjk-16.psf -m 512
"""
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
OUT = HERE / "trha-cjk-16.psf"
W = H = 16

# (font file, face index, codepoints)
FONTS = [
    (
        HERE / "NotoSansCJK-Regular.ttc",
        2,  # 0=JP, 1=KR, 2=SC, 3=TC, 4=HK
        list(range(0x20, 0x7F))          # ASCII
        + list(range(0x3000, 0x3040))    # CJK punctuation
        + list(range(0x4E00, 0xA000))    # unified ideographs
        + list(range(0xFF00, 0xFFF0)),   # fullwidth forms
    ),
    (HERE / "NotoSerifTibetan-Regular.ttf", 0, list(range(0x0F00, 0x1000))),
    (HERE / "NotoSansYi-Regular.ttf", 0, list(range(0xA000, 0xA4D0))),
    (HERE / "NotoSansMyanmar-Regular.ttf", 0, list(range(0x1000, 0x10A0))),
    (HERE / "NotoSansThai-Regular.ttf", 0, list(range(0x0E00, 0x0E80))),
]


def main() -> int:
    glyphs: list[bytes] = []
    codepoints: list[int] = []
    for path, index, cps in FONTS:
        if not path.exists():
            print(f"skip missing {path.name}", file=sys.stderr)
            continue
        font = ImageFont.truetype(str(path), 15, index=index)
        for cp in cps:
            img = Image.new("1", (W, H), 0)
            ImageDraw.Draw(img).text((0, 0), chr(cp), font=font, fill=1)
            glyphs.append(img.tobytes())  # 16 rows x 2 bytes = 32 bytes
            codepoints.append(cp)

    if not glyphs:
        print("no fonts found", file=sys.stderr)
        return 1

    charsize = len(glyphs[0])
    header = struct.pack(
        "<4sIIIIIII",
        b"\x72\xb5\x4a\x86",  # PSF2 magic
        0,                    # version
        32,                   # header size
        1,                    # flags: has unicode table
        len(glyphs),
        charsize,
        H,
        W,
    )
    unicode_table = b"".join(struct.pack("<H", cp) for cp in codepoints)
    unicode_table += struct.pack("<H", 0xFFFF)  # per-glyph terminator

    blob = header + b"".join(glyphs) + unicode_table
    OUT.write_bytes(blob)
    print(f"wrote {OUT} ({len(blob)} bytes, {len(glyphs)} glyphs, {charsize} B/glyph)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
