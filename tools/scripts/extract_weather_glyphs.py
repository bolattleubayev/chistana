#!/usr/bin/env python3
"""
Extracts the 6 weather-condition icons from "images/drafts/weather
glyphs.png" (a 1024x1024 sprite sheet, 3 cols x 2 rows: sunny,
partly-cloudy, cloudy / rain, snow, thunder) into individual
weather_*.png files sized for the bottom weather badge.

Same tight alpha-bbox + pad + scale method as extract_glyphs.py.

Usage:
    python3 extract_weather_glyphs.py [--dry-run]
"""

import sys
import os
from PIL import Image
import numpy as np

DRAWABLES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "resources", "drawables")
)
SHEET_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "images", "drafts", "weather glyphs.png")

COLS = [(101, 326), (387, 655), (711, 926)]
ROWS = [(203, 402), (578, 763)]
SIG_THRESHOLD = 2
PAD = 6
CANVAS = (40, 40)

CELLS = {
    (0, 0): "weather_sunny",
    (0, 1): "weather_partly_cloudy",
    (0, 2): "weather_cloudy",
    (1, 0): "weather_rain",
    (1, 1): "weather_snow",
    (1, 2): "weather_thunder",
}


def tight_bbox(sub):
    rowsum = sub.sum(axis=1)
    colsum = sub.sum(axis=0)
    rows = np.where(rowsum > SIG_THRESHOLD)[0]
    cols = np.where(colsum > SIG_THRESHOLD)[0]
    if len(rows) == 0 or len(cols) == 0:
        return None
    return cols.min(), rows.min(), cols.max() + 1, rows.max() + 1


def main():
    dry_run = "--dry-run" in sys.argv[1:]
    sheet = Image.open(SHEET_PATH).convert("RGBA")
    a = np.array(sheet)
    mask = a[:, :, 3] > 3

    for (r_idx, c_idx), name in sorted(CELLS.items()):
        r0, r1 = ROWS[r_idx]
        c0, c1 = COLS[c_idx]
        sub = mask[r0:r1, c0:c1]
        bbox = tight_bbox(sub)
        if bbox is None:
            print(f"{name}: EMPTY CELL - skipping")
            continue
        lx0, ly0, lx1, ly1 = bbox
        box = (max(0, c0 + lx0 - PAD), max(0, r0 + ly0 - PAD),
               min(sheet.width, c0 + lx1 + PAD), min(sheet.height, r0 + ly1 + PAD))
        crop = sheet.crop(box)

        cw, ch = CANVAS
        scale = min(cw / crop.width, ch / crop.height)
        new_w = max(1, round(crop.width * scale))
        new_h = max(1, round(crop.height * scale))
        resized = crop.resize((new_w, new_h), Image.LANCZOS)

        canvas = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
        canvas.alpha_composite(resized, ((cw - new_w) // 2, (ch - new_h) // 2))

        out_path = os.path.join(DRAWABLES_DIR, f"{name}.png")
        print(f"{name}: sheet-box={box} -> content={new_w}x{new_h} ink-bbox={canvas.getbbox()}")
        if not dry_run:
            canvas.save(out_path)


if __name__ == "__main__":
    main()
