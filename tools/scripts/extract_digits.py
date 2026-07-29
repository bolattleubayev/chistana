#!/usr/bin/env python3
"""
Extracts the time-digit glyphs from images/drafts/digits_2.png (a
1518x240 single-row sheet: 1 2 3 4 5 6 7 8 9 0 :) into digit_0.png ..
digit_9.png and colon.png.

Unlike the original digits.png sheet, this replacement art has NO alpha
channel at all - it's a fully opaque PNG flattened onto a solid white
background (confirmed: every pixel's alpha is 255). Extracting it
therefore needs an extra step the other extract_*.py scripts don't:
reconstructing alpha by classifying each pixel against the sheet's 3
known flat colors (white background, the dark stroke ink, the lighter
flag-stripe ink) via nearest-color distance, rather than reading alpha
directly.

A naive "distance from white" alpha (e.g. 255 - min(R,G,B)) was tried
first and rejected: antialiased edge-blend pixels partway between the
dark ink and white can land on almost the same value as the fully-opaque
*light* ink color (both dilute the red channel by a similar amount), so
that approach either washes the light stripe out to ~70% opacity or
leaves a faint desaturated-blue halo around every glyph. Nearest-color
quantization avoids the ambiguity: every pixel snaps to whichever of the
3 reference colors (measured from the sheet's own dominant color
clusters) it's actually closest to, giving hard but correctly-colored
edges - appropriate here since these glyphs are rendered small and get
downscaled again for the watch face anyway.

Column bands were re-measured for this sheet (non-white content-column
runs, split at the midpoint between adjacent glyphs) since it's a
completely different layout from the original 6x2 grid.

Usage:
    python3 extract_digits.py [--dry-run]
"""

import sys
import os
from PIL import Image
import numpy as np

DRAWABLES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "resources", "drawables")
)
SHEET_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "images", "drafts", "digits_2.png")

# Reference colors measured from the sheet's own dominant non-white pixel
# clusters (see the module docstring) - white background, dark stroke ink,
# light flag-stripe ink.
REF_WHITE = (255, 255, 255)
REF_DARK  = (50, 116, 180)
REF_LIGHT = (115, 191, 249)

# (start_x, end_x) column bands, one per glyph, covering the full sheet
# width edge-to-edge (split at the midpoint between each pair of adjacent
# glyphs' measured content bounds) so tight_bbox can't bleed into a
# neighbor.
COLS = [
    (0, 111),      # 1
    (111, 257),    # 2
    (257, 403),    # 3
    (403, 554),    # 4
    (554, 698),    # 5
    (698, 845),    # 6
    (845, 981),    # 7
    (981, 1130),   # 8
    (1130, 1279),  # 9
    (1279, 1423),  # 0
    (1423, 1518),  # :
]
NAMES = ["digit_1", "digit_2", "digit_3", "digit_4", "digit_5",
         "digit_6", "digit_7", "digit_8", "digit_9", "digit_0", "colon"]

PAD = 6
TARGET_H = 100


def quantize_to_alpha(sheet):
    """Classify every pixel as background/dark-ink/light-ink by nearest
    RGB distance, returning a fresh RGBA array with reconstructed alpha
    and exact reference colors (no in-between blends)."""
    a = np.array(sheet.convert("RGB")).astype(int)
    refs = [REF_WHITE, REF_DARK, REF_LIGHT]
    dists = [np.sum((a - np.array(ref)) ** 2, axis=2) for ref in refs]
    nearest = np.argmin(np.stack(dists, axis=0), axis=0)

    out = np.zeros((a.shape[0], a.shape[1], 4), dtype=np.uint8)
    for i, ref in enumerate(refs):
        m = nearest == i
        out[m, 0] = ref[0]
        out[m, 1] = ref[1]
        out[m, 2] = ref[2]
        out[m, 3] = 0 if i == 0 else 255  # background (i=0) stays transparent
    return out


def tight_bbox(alpha_sub):
    rowsum = (alpha_sub > 0).sum(axis=1)
    colsum = (alpha_sub > 0).sum(axis=0)
    rows = np.where(rowsum > 0)[0]
    cols = np.where(colsum > 0)[0]
    if len(rows) == 0 or len(cols) == 0:
        return None
    return cols.min(), rows.min(), cols.max() + 1, rows.max() + 1


def main():
    dry_run = "--dry-run" in sys.argv[1:]
    sheet = Image.open(SHEET_PATH)
    quantized = quantize_to_alpha(sheet)
    full = Image.fromarray(quantized)
    alpha = quantized[:, :, 3]

    for (c0, c1), name in zip(COLS, NAMES):
        sub_alpha = alpha[:, c0:c1]
        bbox = tight_bbox(sub_alpha)
        if bbox is None:
            print(f"{name}: EMPTY BAND ({c0},{c1}) - skipping")
            continue
        lx0, ly0, lx1, ly1 = bbox
        box = (max(0, c0 + lx0 - PAD), max(0, ly0 - PAD),
               min(full.width, c0 + lx1 + PAD), min(full.height, ly1 + PAD))
        crop = full.crop(box)
        scale = TARGET_H / crop.height
        new_w = max(1, round(crop.width * scale))
        resized = crop.resize((new_w, TARGET_H), Image.LANCZOS)

        out_path = os.path.join(DRAWABLES_DIR, f"{name}.png")
        print(f"{name}: sheet-box={box} -> {resized.size} ink-bbox={resized.getbbox()}")
        if not dry_run:
            resized.save(out_path)


if __name__ == "__main__":
    main()
