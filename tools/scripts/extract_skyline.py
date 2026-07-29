#!/usr/bin/env python3
"""
Tight-crops images/drafts/day_skyline.png and night_skyline.png (each
1536x1024, a single hero graphic - mosque + Baiterek Tower + skyscrapers)
into resources/drawables/day_skyline.png / night_skyline.png, scaled to
span the dial's sky-arc width.

The naive alpha bbox on these sheets is inflated almost to the full
canvas by a soft glow halo around the buildings, so this uses a higher
per-row/column significance threshold (content pixel count, not just
"any nonzero alpha") than the digit/glyph scripts - same technique as
Kadi's extract_new_glyphs.py icon extraction, tuned up further here
since the glow halo is wider on these sheets.

Usage:
    python3 extract_skyline.py [--dry-run]
"""

import sys
import os
from PIL import Image
import numpy as np

DRAWABLES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..", "resources", "drawables")
)
DRAFTS_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "images", "drafts")

SIG_THRESHOLD = 40  # rows/cols need >40 alpha>3 px to count as real content, not glow taper
PAD = 4

# Pre-scaled to the EXACT final on-screen pixel width instead of an
# arbitrary size, then drawn with dc.drawBitmap (unscaled) rather than
# dc.drawScaledBitmap - see ChistanaWatchFace.mc's drawScene. Chistana
# targets fr970 only (454x454), so this is safe to hardcode: matches
# (w * 0.62).toNumber() with w=454 from onLayout, confirmed via a runtime
# debug print. drawScaledBitmap doesn't alpha-blend reliably on this
# simulator/device (see premultiplied_resize's docstring) - real alpha
# only renders correctly through unscaled drawBitmap (confirmed via the
# clouds, which have the same near-black invisible-RGB issue but have
# rendered correctly all session since they're drawn unscaled). The
# skyline needs real alpha (not a baked matte like icon_star/icon_seconds)
# since it's meant to be layered over clouds/sky showing through the gaps
# between buildings - a solid matte would flatten that.
TARGET_W = 281

SHEETS = {
    "day_skyline": os.path.join(DRAFTS_DIR, "day_skyline.png"),
    "night_skyline": os.path.join(DRAFTS_DIR, "night_skyline.png"),
}


def premultiplied_resize(im, size, resample=Image.LANCZOS):
    """Resizes an RGBA image without bleeding the color hidden behind
    transparent pixels into antialiased edges. PIL's plain .resize() treats
    R/G/B/A as independent channels, so a transparent pixel's RGB (often
    black, whatever the source tool left there) gets blended into nearby
    edge pixels' visible colors during the resample - invisible normally
    since alpha still reads ~0 there, but on this device partial-alpha edge
    pixels apparently render as fully opaque, turning that invisible black
    bleed into a visible black box across most of the skyline's bounding
    rectangle (confirmed: night_skyline.png/day_skyline.png have near-black
    RGB under their transparent "glow halo" region, and with a silhouette
    this dense in edges - mosque, tower, skyscrapers - that's a lot of
    fringe). Standard fix: premultiply RGB by alpha before resizing (so
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


def tight_bbox(mask, threshold):
    rowsum = mask.sum(axis=1)
    colsum = mask.sum(axis=0)
    rows = np.where(rowsum > threshold)[0]
    cols = np.where(colsum > threshold)[0]
    if len(rows) == 0 or len(cols) == 0:
        return None
    return cols.min(), rows.min(), cols.max() + 1, rows.max() + 1


def main():
    dry_run = "--dry-run" in sys.argv[1:]
    for name, path in SHEETS.items():
        sheet = Image.open(path).convert("RGBA")
        a = np.array(sheet)
        mask = a[:, :, 3] > 3
        bbox = tight_bbox(mask, SIG_THRESHOLD)
        if bbox is None:
            print(f"{name}: NO CONTENT FOUND at threshold {SIG_THRESHOLD} - skipping")
            continue
        lx0, ly0, lx1, ly1 = bbox
        box = (max(0, lx0 - PAD), max(0, ly0 - PAD),
               min(sheet.width, lx1 + PAD), min(sheet.height, ly1 + PAD))
        crop = sheet.crop(box)
        scale = TARGET_W / crop.width
        new_h = max(1, round(crop.height * scale))
        resized = premultiplied_resize(crop, (TARGET_W, new_h))

        out_path = os.path.join(DRAWABLES_DIR, f"{name}.png")
        print(f"{name}: sheet-box={box} -> {resized.size} ink-bbox={resized.getbbox()}")
        if not dry_run:
            resized.save(out_path)


if __name__ == "__main__":
    main()
