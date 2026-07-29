#!/usr/bin/env python3
"""
Extracts the 5 cloud sprites from images/drafts/day_clouds_2.png and
night_clouds_2.png (each 1536x1024, replacement art for the original
day_clouds.png/night_clouds.png) into day_cloud_1..5.png /
night_cloud_1..5.png.

Layout (measured via per-band alpha-content column runs, re-measured for
this "_2" art since its cloud positions/sizes shifted from the original
sheets - day and night are no longer pixel-aligned to each other either):
top band has 2 clouds (1=big, top-left; 2=small, top-right), bottom band
has 3 (3=small bottom-left; 4=medium bottom-mid; 5=small bottom-right) -
this numbering matches the original sheets' so drawScene()'s cloud
positions/indices don't need to change, just the source art.

Same tight alpha-bbox + pad method as the other extract_*.py scripts,
scaled to a target width preserving aspect ratio (clouds are wide/flat,
so width-constrained rather than height-constrained like the glyphs).

Usage:
    python3 extract_clouds.py [--dry-run]
"""

import sys
import os
from PIL import Image
import numpy as np

DRAWABLES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "resources", "drawables")
)
DRAFTS_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "images", "drafts")

SIG_THRESHOLD = 2
PAD = 6
TARGET_W = 140

SHEETS = {
    "day": {
        "path": os.path.join(DRAFTS_DIR, "day_clouds_2.png"),
        "top_band": (95, 420),
        "bottom_band": (550, 785),
        "top_cols": [(110, 795), (1015, 1449)],
        "bottom_cols": [(120, 410), (485, 1050), (1157, 1459)],
    },
    "night": {
        "path": os.path.join(DRAFTS_DIR, "night_clouds_2.png"),
        "top_band": (95, 445),
        "bottom_band": (547, 790),
        "top_cols": [(80, 820), (998, 1460)],
        "bottom_cols": [(104, 420), (466, 1070), (1138, 1469)],
    },
}


def tight_bbox(sub):
    rowsum = sub.sum(axis=1)
    colsum = sub.sum(axis=0)
    rows = np.where(rowsum > SIG_THRESHOLD)[0]
    cols = np.where(colsum > SIG_THRESHOLD)[0]
    if len(rows) == 0 or len(cols) == 0:
        return None
    return cols.min(), rows.min(), cols.max() + 1, rows.max() + 1


def extract_one(sheet, band, col_range, prefix, num, dry_run):
    r0, r1 = band
    c0, c1 = col_range
    a = np.array(sheet)
    mask = a[:, :, 3] > 3
    sub = mask[r0:r1, c0:c1]
    bbox = tight_bbox(sub)
    name = f"{prefix}_cloud_{num}"
    if bbox is None:
        print(f"{name}: EMPTY REGION - skipping")
        return
    lx0, ly0, lx1, ly1 = bbox
    box = (max(0, c0 + lx0 - PAD), max(0, r0 + ly0 - PAD),
           min(sheet.width, c0 + lx1 + PAD), min(sheet.height, r0 + ly1 + PAD))
    crop = sheet.crop(box)
    scale = TARGET_W / crop.width
    new_h = max(1, round(crop.height * scale))
    resized = crop.resize((TARGET_W, new_h), Image.LANCZOS)

    out_path = os.path.join(DRAWABLES_DIR, f"{name}.png")
    print(f"{name}: sheet-box={box} -> {resized.size} ink-bbox={resized.getbbox()}")
    if not dry_run:
        resized.save(out_path)


def main():
    dry_run = "--dry-run" in sys.argv[1:]
    for prefix, cfg in SHEETS.items():
        sheet = Image.open(cfg["path"]).convert("RGBA")
        for i, col_range in enumerate(cfg["top_cols"], start=1):
            extract_one(sheet, cfg["top_band"], col_range, prefix, i, dry_run)
        for i, col_range in enumerate(cfg["bottom_cols"], start=3):
            extract_one(sheet, cfg["bottom_band"], col_range, prefix, i, dry_run)


if __name__ == "__main__":
    main()
