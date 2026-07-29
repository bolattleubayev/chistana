#!/usr/bin/env python3
"""
Extracts the sun icon from images/drafts/sun.png (single sprite,
1024x1024) and the 8 moon-phase icons from images/drafts/moon_phases.png
(1024x1024, 4 cols x 2 rows) into sun.png / moon_phase_0..7.png in
resources/drawables/.

The raw sheet's 8 cells are NOT a clean evenly-spaced new->full->new
sequence: measuring each cell's lit-fraction and lit-side (see the pixel
analysis done when this was diagnosed) shows the artist only actually
drew 4 distinct "right-lit" (waxing) shapes and 4 "left-lit" (waning)
shapes, and skipped a true ~80%-lit waxing-gibbous shape entirely - the
naive row-major reading put the sheet's true full moon (cell row0col3)
at index 3 instead of index 4, which is where Conway's algorithm (see
updateMoonPhase() in ChistanaWatchFace.mc) actually expects "full".

MOON_TARGETS below is an explicit, hand-verified remap so moon_phase_N
matches Conway's algorithm's own semantics (0=new, 4=full, mirrored
waxing 1-3 / waning 5-7), reusing the sheet's own cells - including one
horizontal mirror of the waning-gibbous cell to stand in for the
waxing-gibbous shape the sheet never drew.

Same tight alpha-bbox + pad + scale method as the other extract_*.py
scripts.

Usage:
    python3 extract_moon_and_sun.py [--dry-run]
"""

import sys
import os
from PIL import Image, ImageOps
import numpy as np

DRAWABLES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "resources", "drawables")
)
DRAFTS_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "images", "drafts")

SIG_THRESHOLD = 2
PAD = 6

MOON_COLS = [(73, 224), (321, 469), (537, 684), (775, 925)]
MOON_ROWS = [(332, 480), (551, 702)]
MOON_CANVAS = (56, 56)

# (output index, row index into MOON_ROWS, col index into MOON_COLS, mirror?)
MOON_TARGETS = [
    (0, 0, 0, False),  # new (empty disc)
    (1, 1, 2, False),  # waxing crescent, ~25% lit on the right
    (2, 0, 2, False),  # first quarter, 50% lit on the right
    (3, 1, 0, True),   # waxing gibbous - sheet has no such cell, so mirror
                        # the waning-gibbous cell (right-lit instead of left)
    (4, 0, 3, False),  # full
    (5, 1, 0, False),  # waning gibbous, ~77% lit on the left
    (6, 1, 1, False),  # last quarter, 50% lit on the left
    (7, 0, 1, False),  # waning crescent, ~23% lit on the left
]

SUN_CANVAS = (60, 60)


def tight_bbox(sub):
    rowsum = sub.sum(axis=1)
    colsum = sub.sum(axis=0)
    rows = np.where(rowsum > SIG_THRESHOLD)[0]
    cols = np.where(colsum > SIG_THRESHOLD)[0]
    if len(rows) == 0 or len(cols) == 0:
        return None
    return cols.min(), rows.min(), cols.max() + 1, rows.max() + 1


def crop_and_fit(sheet, box, canvas_size):
    crop = sheet.crop(box)
    cw, ch = canvas_size
    scale = min(cw / crop.width, ch / crop.height)
    new_w = max(1, round(crop.width * scale))
    new_h = max(1, round(crop.height * scale))
    resized = crop.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    canvas.alpha_composite(resized, ((cw - new_w) // 2, (ch - new_h) // 2))
    return canvas


def main():
    dry_run = "--dry-run" in sys.argv[1:]

    moon_sheet = Image.open(os.path.join(DRAFTS_DIR, "moon_phases.png")).convert("RGBA")
    m = np.array(moon_sheet)
    mmask = m[:, :, 3] > 3

    for idx, row_i, col_i, mirror in MOON_TARGETS:
        r0, r1 = MOON_ROWS[row_i]
        c0, c1 = MOON_COLS[col_i]
        sub = mmask[r0:r1, c0:c1]
        bbox = tight_bbox(sub)
        name = f"moon_phase_{idx}"
        if bbox is None:
            print(f"{name}: EMPTY CELL - skipping")
            continue
        lx0, ly0, lx1, ly1 = bbox
        box = (max(0, c0 + lx0 - PAD), max(0, r0 + ly0 - PAD),
               min(moon_sheet.width, c0 + lx1 + PAD), min(moon_sheet.height, r0 + ly1 + PAD))
        cell = moon_sheet.crop(box)
        if mirror:
            cell = ImageOps.mirror(cell)
        cw, ch = MOON_CANVAS
        scale = min(cw / cell.width, ch / cell.height)
        new_w = max(1, round(cell.width * scale))
        new_h = max(1, round(cell.height * scale))
        resized = cell.resize((new_w, new_h), Image.LANCZOS)
        canvas = Image.new("RGBA", MOON_CANVAS, (0, 0, 0, 0))
        canvas.alpha_composite(resized, ((cw - new_w) // 2, (ch - new_h) // 2))
        print(f"{name}: sheet-box={box} mirror={mirror} -> ink-bbox={canvas.getbbox()}")
        if not dry_run:
            canvas.save(os.path.join(DRAWABLES_DIR, f"{name}.png"))

    sun_sheet = Image.open(os.path.join(DRAFTS_DIR, "sun.png")).convert("RGBA")
    s = np.array(sun_sheet)
    smask = s[:, :, 3] > 3
    bbox = tight_bbox(smask)
    lx0, ly0, lx1, ly1 = bbox
    box = (max(0, lx0 - PAD), max(0, ly0 - PAD),
           min(sun_sheet.width, lx1 + PAD), min(sun_sheet.height, ly1 + PAD))
    canvas = crop_and_fit(sun_sheet, box, SUN_CANVAS)
    print(f"sun: sheet-box={box} -> ink-bbox={canvas.getbbox()}")
    if not dry_run:
        canvas.save(os.path.join(DRAWABLES_DIR, "sun.png"))


if __name__ == "__main__":
    main()
