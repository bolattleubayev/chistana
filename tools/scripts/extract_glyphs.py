#!/usr/bin/env python3
"""
Extracts stat/decoration icons for the watch face.

icon_star still comes from the original images/drafts/glyphs.png sheet
(1024x1024, 2x2 grid, alpha-clean) - untouched.

icon_heart, icon_steps, and icon_run come from the replacement
images/drafts/glyphs_2.png sheet (786x376, 3 icons left-to-right: running
person, heart, footprints). Like digits_2.png, this sheet has NO alpha
channel - it's fully opaque, flattened onto a solid white background - so
extraction reconstructs alpha via nearest-color classification against
the sheet's only two colors (white background, the single flat red ink)
rather than reading alpha directly. There's just one ink color here
(unlike digits_2.png's two), so this is a plain white-vs-red distance
classification.

The footprints icon's two shoe prints have a gap between them wider than
a naive column-run split threshold would tolerate, so it's handled as one
wide column band rather than auto-split per-glyph like the original
grid-based extraction - simpler and correct since there are only 3 icons
here, not a dense grid.

Usage:
    python3 extract_glyphs.py [--dry-run]
"""

import sys
import os
from PIL import Image
import numpy as np

DRAWABLES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "resources", "drawables")
)
DRAFTS_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "images", "drafts")

OLD_SHEET_PATH = os.path.join(DRAFTS_DIR, "glyphs.png")
NEW_SHEET_PATH = os.path.join(DRAFTS_DIR, "glyphs_2.png")

SIG_THRESHOLD = 2
PAD = 6

# icon_star always sits on the ring band (see drawRing in
# ChistanaWatchFace.mc), which is a solid COLOR_NAVY stroke regardless of
# day/night/scene behind it - so its "transparent" background is baked in
# as opaque navy rather than left as real alpha. This works around a
# simulator/device quirk where drawScaledBitmap doesn't alpha-blend
# reliably (partial/zero-alpha pixels can render fully opaque using
# whatever RGB is stored there, showing as a black box instead of blending
# with whatever's actually behind them) - baking the correct opaque color
# in up front sidesteps needing alpha at all for this icon.
MATTE_NAVY = (0x0C, 0x4A, 0x82)

OLD_COLS = [(197, 436), (575, 824)]
OLD_ROWS = [(177, 425), (574, 777)]
OLD_CELLS = {
    (0, 0): ("icon_star", (36, 36)),
}

REF_WHITE = (255, 255, 255)
REF_RED = (218, 59, 38)

# (start_x, end_x) column bands, one per icon - covers the full sheet
# width, split at the midpoint between each pair of adjacent icons.
NEW_COLS = [
    (0, 258),    # running person -> icon_run
    (258, 519),  # heart -> icon_heart
    (519, 786),  # footprints (2 shoe prints, one band) -> icon_steps
]
NEW_NAMES_SIZES = [
    ("icon_run", (26, 26)),
    ("icon_heart", (24, 24)),
    ("icon_steps", (29, 29)),
]


def tight_bbox(sub):
    rowsum = sub.sum(axis=1)
    colsum = sub.sum(axis=0)
    rows = np.where(rowsum > SIG_THRESHOLD)[0]
    cols = np.where(colsum > SIG_THRESHOLD)[0]
    if len(rows) == 0 or len(cols) == 0:
        return None
    return cols.min(), rows.min(), cols.max() + 1, rows.max() + 1


def premultiplied_resize(im, size, resample=Image.LANCZOS):
    """Resizes an RGBA image without bleeding the color hidden behind
    transparent pixels into antialiased edges. PIL's plain .resize() treats
    R/G/B/A as independent channels, so a transparent pixel's RGB (often
    black, whatever the source tool left there) gets blended into nearby
    edge pixels' visible colors during the resample - invisible on-screen
    normally since alpha still reads ~0 there, but on this device partial-
    alpha edge pixels apparently render as fully opaque, turning that
    invisible black bleed into a visible black fringe/box (this is what
    caused icon_star's and icon_seconds' black-square artifact - glyphs.png
    and seconds_3.png both have near-black RGB under their transparent
    regions). Standard fix: premultiply RGB by alpha before resizing (so
    fully-transparent pixels contribute zero, not their hidden color),
    resize, then un-premultiply.
    """
    im = im.convert("RGBA")
    arr = np.asarray(im).astype(np.float32)
    a = arr[:, :, 3:4] / 255.0
    premult = (arr[:, :, :3] * a).astype(np.uint8)
    premult_img = Image.fromarray(premult, "RGB").resize(size, resample)
    alpha_img = Image.fromarray(arr[:, :, 3].astype(np.uint8), "L").resize(size, resample)

    p = np.asarray(premult_img).astype(np.float32)
    a2 = np.asarray(alpha_img).astype(np.float32) / 255.0
    with np.errstate(divide="ignore", invalid="ignore"):
        rgb2 = np.where(a2[:, :, None] > 1e-3, p / np.maximum(a2[:, :, None], 1e-3), 0)
    out = np.dstack([np.clip(rgb2, 0, 255).astype(np.uint8), (a2 * 255).astype(np.uint8)])
    return Image.fromarray(out, "RGBA")


def save_cell(box, name, canvas_size, dry_run, source_img, matte=None):
    crop = source_img.crop(box)
    cw, ch = canvas_size
    scale = min(cw / crop.width, ch / crop.height)
    new_w = max(1, round(crop.width * scale))
    new_h = max(1, round(crop.height * scale))
    resized = premultiplied_resize(crop, (new_w, new_h))

    bg = matte + (255,) if matte is not None else (0, 0, 0, 0)
    canvas = Image.new("RGBA", canvas_size, bg)
    canvas.alpha_composite(resized, ((cw - new_w) // 2, (ch - new_h) // 2))
    if matte is not None:
        canvas = canvas.convert("RGB").convert("RGBA")  # drop alpha, fully opaque

    out_path = os.path.join(DRAWABLES_DIR, f"{name}.png")
    print(f"{name}: sheet-box={box} -> canvas={canvas_size} content={new_w}x{new_h} ink-bbox={canvas.getbbox()}")
    if not dry_run:
        canvas.save(out_path)


def quantize_to_alpha(sheet_rgb):
    a = np.array(sheet_rgb.convert("RGB")).astype(int)
    refs = [REF_WHITE, REF_RED]
    dists = [np.sum((a - np.array(ref)) ** 2, axis=2) for ref in refs]
    nearest = np.argmin(np.stack(dists, axis=0), axis=0)

    out = np.zeros((a.shape[0], a.shape[1], 4), dtype=np.uint8)
    for i, ref in enumerate(refs):
        m = nearest == i
        out[m, 0] = ref[0]
        out[m, 1] = ref[1]
        out[m, 2] = ref[2]
        out[m, 3] = 0 if i == 0 else 255
    return out


def main():
    dry_run = "--dry-run" in sys.argv[1:]

    # icon_star: unchanged original alpha-clean sheet
    old_sheet = Image.open(OLD_SHEET_PATH).convert("RGBA")
    old_a = np.array(old_sheet)
    old_mask = old_a[:, :, 3] > 3
    for (r_idx, c_idx), (name, canvas_size) in sorted(OLD_CELLS.items()):
        r0, r1 = OLD_ROWS[r_idx]
        c0, c1 = OLD_COLS[c_idx]
        sub = old_mask[r0:r1, c0:c1]
        bbox = tight_bbox(sub)
        if bbox is None:
            print(f"{name}: EMPTY CELL - skipping")
            continue
        lx0, ly0, lx1, ly1 = bbox
        box = (max(0, c0 + lx0 - PAD), max(0, r0 + ly0 - PAD),
               min(old_sheet.width, c0 + lx1 + PAD), min(old_sheet.height, r0 + ly1 + PAD))
        save_cell(box, name, canvas_size, dry_run, old_sheet, matte=MATTE_NAVY)

    # icon_heart / icon_steps / icon_run: flat white-background replacement sheet
    new_sheet = Image.open(NEW_SHEET_PATH)
    quantized = quantize_to_alpha(new_sheet)
    full = Image.fromarray(quantized)
    alpha = quantized[:, :, 3]

    for (c0, c1), (name, canvas_size) in zip(NEW_COLS, NEW_NAMES_SIZES):
        sub_alpha = (alpha[:, c0:c1] > 0).astype(np.uint8)
        bbox = tight_bbox(sub_alpha)
        if bbox is None:
            print(f"{name}: EMPTY BAND ({c0},{c1}) - skipping")
            continue
        lx0, ly0, lx1, ly1 = bbox
        box = (max(0, c0 + lx0 - PAD), max(0, ly0 - PAD),
               min(full.width, c0 + lx1 + PAD), min(full.height, ly1 + PAD))
        save_cell(box, name, canvas_size, dry_run, full)


if __name__ == "__main__":
    main()
