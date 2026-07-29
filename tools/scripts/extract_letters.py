#!/usr/bin/env python3
"""
Extracts the letter glyphs needed for the ring-text names ("KADISHA" /
"MUKHAMEDJANOVA") from images/drafts/letters_2.png (1024x768, alpha-clean,
3 rows: QWERTYUIOP / ASDFGHJKLZX / CVBNM - a plain solid-fill sans-serif,
replacing the original letters.png striped/lined font, which moire'd badly
when the ring-text draw code downscaled it - see drawArcLetter's comment).

Row/column bands were measured by auto-detecting contiguous nonzero-alpha
row bands, then per-row contiguous nonzero-alpha column bands (gap > 5px
counts as a letter boundary) - this sheet is alpha-clean so no color
quantization is needed, unlike digits_2.png/glyphs_2.png.

Only the 13 unique letters actually used by the two names are extracted,
not the full alphabet - no point baking resources the watch face never
draws.

Usage:
    python3 extract_letters.py [--dry-run]
"""

import sys
import os
from PIL import Image
import numpy as np

DRAWABLES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "resources", "drawables")
)
SHEET_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "images", "drafts", "letters_2.png")

PAD = 4
TARGET_H = 48

ROW_BANDS = [(191, 275), (342, 424), (493, 580)]
ROW_LETTERS = [
    list("QWERTYUIOP"),
    list("ASDFGHJKLZX"),
    list("CVBNM"),
]
ROW_COLS = [
    [(17, 98), (133, 238), (278, 320), (365, 415), (449, 495), (526, 587), (626, 683), (731, 743), (788, 867), (912, 955)],
    [(12, 86), (122, 171), (215, 274), (318, 357), (396, 471), (515, 571), (609, 643), (691, 748), (788, 822), (858, 914), (949, 1009)],
    [(17, 77), (113, 180), (220, 266), (310, 377), (423, 506)],
]

NEEDED = set("KADISHAMUKHEDJNOVTCG")  # union of "KADISHA" + "MUKHAMEDJANOVA" + "ASTANA" + "CHICAGO"


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
    sheet = Image.open(SHEET_PATH).convert("RGBA")
    alpha = np.array(sheet)[:, :, 3]

    for (r0, r1), letters, cbands in zip(ROW_BANDS, ROW_LETTERS, ROW_COLS):
        for letter, (c0, c1) in zip(letters, cbands):
            if letter not in NEEDED:
                continue
            sub = alpha[r0:r1 + 1, c0:c1 + 1]
            bbox = tight_bbox(sub)
            if bbox is None:
                print(f"{letter}: EMPTY CELL - skipping")
                continue
            lx0, ly0, lx1, ly1 = bbox
            box = (max(0, c0 + lx0 - PAD), max(0, r0 + ly0 - PAD),
                   min(sheet.width, c0 + lx1 + PAD), min(sheet.height, r0 + ly1 + PAD))
            crop = sheet.crop(box)
            scale = TARGET_H / crop.height
            new_w = max(1, round(crop.width * scale))
            resized = crop.resize((new_w, TARGET_H), Image.LANCZOS)

            name = f"letter_{letter.lower()}"
            out_path = os.path.join(DRAWABLES_DIR, f"{name}.png")
            print(f"{name}: sheet-box={box} -> {resized.size}")
            if not dry_run:
                resized.save(out_path)


if __name__ == "__main__":
    main()
