#!/usr/bin/env python3
"""
Extracts the seconds-indicator marker from images/drafts/seconds_3.png
(1024x768, single sprite: a leaf/plant emblem) into
resources/drawables/icon_seconds.png.

Unlike seconds.png/seconds_2.png (both outline/line-art, needing
fill_holes() below to collapse into a solid marker), seconds_3.png is
already a solid filled silhouette with two small intentional negative-
space cutouts (the "eyes" between the leaves) - so it's extracted with a
plain tight alpha-bbox crop, same as extract_moon_and_sun.py's sun
extraction, with no fill step (that would wrongly paint over the cutouts).

The sheet looks like a faint, glowing white-on-white badge when viewed
flattened, but that's misleading - its alpha channel alone is a clean,
crisp silhouette (verified by rendering the alpha channel on its own),
with RGB just uniformly near-white fill.

Saved with REAL per-pixel alpha (no opaque matte baked in) - unlike the
MATTE_NAVY approach an earlier version of this script used. That baked
matte was a workaround for drawScaledBitmap's unreliable alpha blending,
but drawSecondsMarker (ChistanaWatchFace.mc) draws this icon unscaled via
plain dc.drawBitmap, which this project's other assets (see drawScene's
skyline comment) confirm blends real alpha correctly - baking a matte
here only produced a visible opaque square over the marker's light-blue
bubble background instead of a transparent icon.

fill_holes() is kept below (unused for this sheet) since it's a generic
"collapse outline art into a solid marker" tool that may be needed again
if a future replacement sheet is line-art rather than already-filled -
see its docstring for why it's a hand-rolled numpy flood fill rather than
PIL.ImageDraw.floodfill.

Usage:
    python3 extract_seconds.py [--dry-run]
"""

import sys
import os
from PIL import Image
import numpy as np

DRAWABLES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "resources", "drawables")
)
SHEET_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "images", "drafts", "seconds_3.png")

SIG_THRESHOLD = 3
PAD = 6
# Final icon height in px - drawSecondsMarker (ChistanaWatchFace.mc) draws
# this unscaled at whatever size it's saved at, centered in a bubble of
# radius (mRingPen/2 - 4) (~13px at fr970's dimensions, ~26px diameter) -
# 22 leaves a couple px of margin on every side of that circular bubble
# for this icon's roughly-square bounding box.
TARGET_H = 22


def tight_bbox(mask):
    rowsum = mask.sum(axis=1)
    colsum = mask.sum(axis=0)
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
    edge pixels' visible colors during the resample - invisible normally
    since alpha still reads ~0 there, but on this device partial-alpha edge
    pixels apparently render as fully opaque, turning that invisible black
    bleed into a visible black square around the icon (seconds_3.png has
    pure black RGB under its transparent regions, confirmed via inspection -
    that's what caused it). Standard fix: premultiply RGB by alpha before
    resizing (so fully-transparent pixels contribute zero, not their hidden
    color), resize, then un-premultiply.
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


def flood_fill_from_border(bg_mask):
    """4-connectivity flood fill seeded from every border pixel that's
    background, via repeated dilation until it stops changing. Plain numpy,
    no PIL floodfill involved (see module docstring for why)."""
    outside = np.zeros_like(bg_mask)
    outside[0, :] = bg_mask[0, :]
    outside[-1, :] = bg_mask[-1, :]
    outside[:, 0] = bg_mask[:, 0]
    outside[:, -1] = bg_mask[:, -1]

    while True:
        grown = outside.copy()
        grown[1:, :] |= outside[:-1, :] & bg_mask[1:, :]
        grown[:-1, :] |= outside[1:, :] & bg_mask[:-1, :]
        grown[:, 1:] |= outside[:, :-1] & bg_mask[:, 1:]
        grown[:, :-1] |= outside[:, 1:] & bg_mask[:, :-1]
        if np.array_equal(grown, outside):
            return outside
        outside = grown


def fill_holes(crop_rgba):
    """Collapses outline art into a solid white silhouette: flood-fills the
    background starting from the crop's border (guaranteed transparent,
    thanks to the PAD margin), then fills everything that flood fill never
    reached - the strokes themselves and any fully-enclosed gaps between
    them - as opaque white.

    The fill is a hand-rolled vectorized flood fill (repeated 4-connectivity
    dilation via numpy array shifts, iterating to a fixed point), not
    PIL.ImageDraw.floodfill - that one silently no-ops on these sheets at
    full (~800px) resolution for reasons that didn't reproduce at smaller
    sizes (verified: identical seed/threshold/mode works fine on a 100x100
    copy of the same mask, so the failure is size-related, not a logic bug
    on our end). The numpy version has no such cliff and is easy to verify
    directly.
    """
    a = np.array(crop_rgba)
    bg_mask = a[:, :, 3] <= 3
    reached_outside = flood_fill_from_border(bg_mask)
    fill_mask = ~reached_outside

    out = a.copy()
    out[fill_mask] = [255, 255, 255, 255]
    out[reached_outside] = [255, 255, 255, 0]
    return Image.fromarray(out)


def main():
    dry_run = "--dry-run" in sys.argv[1:]
    sheet = Image.open(SHEET_PATH).convert("RGBA")
    a = np.array(sheet)
    mask = a[:, :, 3] > 3
    bbox = tight_bbox(mask)
    lx0, ly0, lx1, ly1 = bbox
    box = (max(0, lx0 - PAD), max(0, ly0 - PAD),
           min(sheet.width, lx1 + PAD), min(sheet.height, ly1 + PAD))
    crop = sheet.crop(box)

    scale = TARGET_H / crop.height
    new_w = max(1, round(crop.width * scale))
    resized = premultiplied_resize(crop, (new_w, TARGET_H))

    out_path = os.path.join(DRAWABLES_DIR, "icon_seconds.png")
    print(f"icon_seconds: sheet-box={box} -> {resized.size}")
    if not dry_run:
        resized.save(out_path)


if __name__ == "__main__":
    main()
