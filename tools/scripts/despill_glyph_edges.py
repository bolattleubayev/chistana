#!/usr/bin/env python3
"""
Removes green chroma-key/compositing spill from the edge (low-alpha,
antialiased) pixels of glyph PNGs, without touching alpha or any
fully-opaque pixel.

Background: the digit glyphs (hour_digit_*.png / min_digit_*.png, cropped
from digits1.png) and icon_thermometer.png carry faint green-tinted pixels
along their antialiased edges - residue from a green-screen/chroma-key
composite in their original source art that wasn't fully keyed out. The
green channel is measurably higher than both red and blue on these edge
pixels; interior/opaque pixels are unaffected.

This is a narrow, objective technical fix, not a redraw:
  - Alpha is never modified, so glyph shape/bounding boxes are unchanged
    and every ink-measurement table already hardcoded in the watch face
    source (HOUR_INK_W/PAD_LEFT/INK_TOP etc.) stays valid as-is.
  - Only pixels matching the green-spill signature are touched; their RGB
    is desaturated toward the pixel's own red/blue mix (a standard
    despill: green channel clamped to max(red, blue)), not replaced with
    a new color.
  - Fully-opaque interior pixels (alpha >= OPAQUE_ALPHA_THRESHOLD) are
    left alone entirely, even if they happen to trip the color heuristic,
    since the defect only ever appears in the low-alpha edge fringe.

Usage:
    python3 despill_glyph_edges.py [--dry-run] [file_or_dir ...]

With no paths given, processes the default file list below (the assets
this audit identified as affected). Prints a per-file before/after pixel
count and asserts each file's alpha-bounding-box is byte-identical after
processing, so re-running this script is always safe and verifiable.
"""

import sys
import os
from PIL import Image
import numpy as np

GREEN_MARGIN = 30          # G must exceed both R and B by this much to count as spill
OPAQUE_ALPHA_THRESHOLD = 250  # pixels this opaque are real ink, never touched

DEFAULT_TARGETS = [
    "hour_digit_0.png", "hour_digit_1.png", "hour_digit_2.png", "hour_digit_3.png",
    "hour_digit_4.png", "hour_digit_5.png", "hour_digit_6.png", "hour_digit_7.png",
    "hour_digit_8.png", "hour_digit_9.png",
    "min_digit_0.png", "min_digit_1.png", "min_digit_2.png", "min_digit_3.png",
    "min_digit_4.png", "min_digit_5.png", "min_digit_6.png", "min_digit_7.png",
    "min_digit_8.png", "min_digit_9.png",
    "icon_thermometer.png",
]

DRAWABLES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "resources", "drawables")
)


def despill(path, dry_run=False):
    im = Image.open(path).convert("RGBA")
    before_bbox = im.getbbox()
    a = np.array(im)
    r = a[:, :, 0].astype(int)
    g = a[:, :, 1].astype(int)
    b = a[:, :, 2].astype(int)
    alpha = a[:, :, 3]

    spill_mask = (
        (alpha > 0)
        & (alpha < OPAQUE_ALPHA_THRESHOLD)
        & (g > r + GREEN_MARGIN)
        & (g > b + GREEN_MARGIN)
    )
    n = int(spill_mask.sum())
    if n == 0:
        print(f"{os.path.basename(path):22s} clean, no change")
        return 0

    fixed = a.copy()
    max_rb = np.maximum(r, b)
    new_g = np.where(spill_mask, max_rb, g)
    fixed[:, :, 1] = new_g.astype(np.uint8)
    # alpha, red, blue channels are untouched by construction

    out_im = Image.fromarray(fixed)
    after_bbox = out_im.getbbox()
    assert after_bbox == before_bbox, (
        f"{path}: alpha bbox changed ({before_bbox} -> {after_bbox}) - "
        "refusing to write, this script must never alter shape/alpha"
    )

    print(f"{os.path.basename(path):22s} despilled {n} px (bbox unchanged: {after_bbox})")
    if not dry_run:
        out_im.save(path)
    return n


def main():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    paths = [a for a in args if a != "--dry-run"]

    if not paths:
        paths = [os.path.join(DRAWABLES_DIR, name) for name in DEFAULT_TARGETS]
    else:
        expanded = []
        for p in paths:
            if os.path.isdir(p):
                expanded.extend(
                    os.path.join(p, f) for f in sorted(os.listdir(p)) if f.lower().endswith(".png")
                )
            else:
                expanded.append(p)
        paths = expanded

    total = 0
    for p in paths:
        total += despill(p, dry_run=dry_run)
    print(f"\nTotal pixels despilled: {total}{' (dry run, nothing written)' if dry_run else ''}")


if __name__ == "__main__":
    main()
