#!/usr/bin/env python3
"""Turn one 1024 artwork into MoxSpeak.icns.

Two things this does that a plain `sips` resize does not:

1. **Masks to Apple's squircle.** macOS icons are a superellipse with continuous
   corner curvature, not a rounded rectangle, and they occupy 824 of a 1024 canvas
   with transparent margin. Art that runs to the edge of its own canvas renders
   oversized next to every stock icon.

2. **Crops in for the small sizes.** Fine detail — in this icon, the sound-wave
   arcs — turns to mush at 32px and below. Apple ships different artwork per size
   for exactly this reason. Here the small tiles zoom onto the subject so it fills
   the space and stays recognisable, which is all a 16px icon has to do.

Usage:  Scripts/make-icon.py Assets/icon-source.png Assets/MoxSpeak.icns
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

# Measured off the shipping system icons rather than taken from the template. Apple's
# published grid puts the artwork at 824 of 1024, but Mail, Notes, Music and Safari all
# actually fill 850 — 83.0% across the centre, identical to one decimal place. Built to
# the documented 824 the icon renders about 3% smaller than everything beside it in the
# Dock and the app switcher, which is small enough to look like a mistake rather than a
# choice, and is exactly what got noticed.
GRID = 850 / 1024
# |x|^n + |y|^n = 1 approximates the macOS squircle. 5.0 is the figure usually quoted,
# but fitted against the corner profile of the shipping system icons the best match is
# 4.4: at 5.0 the corners are measurably squarer than Mail's and Notes'. Fitted by
# sampling icon width at several heights and minimising the difference.
SUPERELLIPSE_N = 4.4
SUPERSAMPLE = 8
# Below this pixel size, zoom onto the subject instead of showing the whole scene.
SMALL_SIZE_THRESHOLD = 40
SMALL_SIZE_ZOOM = 0.62     # Keep the middle 62%, which is the gem without the arcs.


def squircle_mask(size: int) -> Image.Image:
    big = size * SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    half = big / 2.0
    for yi in range(big):
        y = (yi + 0.5 - half) / half
        ay = abs(y) ** SUPERELLIPSE_N
        if ay >= 1.0:
            continue
        x = (1.0 - ay) ** (1.0 / SUPERELLIPSE_N)
        draw.line([(half - x * half, yi), (half + x * half, yi)], fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def tile(source: Image.Image, size: int) -> Image.Image:
    art_px = max(1, round(size * GRID))
    art = source
    if size <= SMALL_SIZE_THRESHOLD:
        keep = round(source.width * SMALL_SIZE_ZOOM)
        off = (source.width - keep) // 2
        art = source.crop((off, off, off + keep, off + keep))
    art = art.resize((art_px, art_px), Image.LANCZOS).convert("RGBA")
    art.putalpha(squircle_mask(art_px))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - art_px) // 2
    out.paste(art, (off, off), art)
    return out


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    source_path, icns_path = Path(sys.argv[1]), Path(sys.argv[2])
    source = Image.open(source_path).convert("RGB")
    if source.width != source.height:
        print(f"error: {source_path} is {source.width}x{source.height}, expected a square")
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "MoxSpeak.iconset"
        iconset.mkdir()
        for base in (16, 32, 128, 256, 512):
            tile(source, base).save(iconset / f"icon_{base}x{base}.png")
            tile(source, base * 2).save(iconset / f"icon_{base}x{base}@2x.png")
        icns_path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns_path)],
                       check=True)
    print(f"wrote {icns_path} ({icns_path.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
