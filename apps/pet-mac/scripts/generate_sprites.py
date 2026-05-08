#!/usr/bin/env python3
"""Generate AOPet sprite frames from the oneko.js source GIF.

Source: https://github.com/adryd325/oneko.js (MIT). The bundled atlas is
256x128, organized as an 8 (col) x 4 (row) grid of 32x32 frames. The
mapping below is taken verbatim from oneko.js's `spriteSets` table — see
the project README.

This script writes one PNG per (mood, frame) under:
    apps/pet-mac/Sources/AOPet/Resources/sprites/<set>/<mood>_<n>.png
"""
from __future__ import annotations
import os
import sys
import urllib.request
from PIL import Image

ATLAS_URL = "https://raw.githubusercontent.com/adryd325/oneko.js/main/oneko.gif"
TILE = 32

# Verbatim from oneko.js. Coordinates are [col_neg, row_neg] where the
# CSS background-position is `${col_neg*32}px ${row_neg*32}px`, i.e. the
# tile at (col=-col_neg, row=-row_neg).
ONEKO_SPRITES = {
    "idle":         [[-3, -3]],
    "alert":        [[-7, -3]],
    "scratchSelf":  [[-5,  0], [-6,  0], [-7,  0]],
    "scratchWallN": [[0,  0], [0, -1]],
    "scratchWallS": [[-7, -1], [-6, -2]],
    "scratchWallE": [[-2, -2], [-2, -3]],
    "scratchWallW": [[-4,  0], [-4, -1]],
    "tired":        [[-3, -2]],
    "sleeping":     [[-2,  0], [-2, -1]],
    "N":  [[-1, -2], [-1, -3]],
    "NE": [[0,  -2], [0,  -3]],
    "E":  [[-3,  0], [-3, -1]],
    "SE": [[-5, -1], [-5, -2]],
    "S":  [[-6, -3], [-7, -2]],
    "SW": [[-5, -3], [-6, -1]],
    "W":  [[-4, -2], [-4, -3]],
    "NW": [[-1,  0], [-1, -1]],
}

# AO PetMood -> ordered list of (oneko_key, oneko_frame_index) per output
# frame. Frame-count rules:
#   * Every mood ships >= 2 frames so the animation cycle has something
#     to advance through.
#   * Walks (working) use both E frames at 8 fps for a real walk cycle.
#   * Static moods (happy, sad) blink between two close poses.
MOOD_TO_FRAMES = {
    "sleeping": [("sleeping", 0), ("sleeping", 1)],
    "working":  [("E", 0),        ("E", 1)],
    "happy":    [("idle", 0),     ("tired", 0)],
    "sad":      [("alert", 0),    ("idle", 0)],
    "alert":    [("scratchSelf", 0), ("scratchSelf", 1), ("scratchSelf", 2)],
}

# Bundled sets. Each set is the same oneko atlas optionally retinted so
# the "Switch sprite" menu does something visible. License/NOTICE still
# covers all three since the source pixels are unchanged.
BUNDLED_SETS = ["oneko", "cat", "dog"]

# RGB multiplicative tint applied per-set to non-transparent pixels.
# (1, 1, 1) keeps the original art. cat = cooler grey, dog = warm brown.
SET_TINTS: dict[str, tuple[float, float, float]] = {
    "oneko": (1.00, 1.00, 1.00),
    "cat":   (0.78, 0.82, 0.92),
    "dog":   (1.10, 0.85, 0.55),
}


def fetch_atlas(dest: str) -> str:
    if os.path.exists(dest):
        return dest
    print(f"Fetching {ATLAS_URL} -> {dest}")
    urllib.request.urlretrieve(ATLAS_URL, dest)
    return dest


def crop_tile(atlas: Image.Image, col_neg: int, row_neg: int) -> Image.Image:
    col = -col_neg
    row = -row_neg
    box = (col * TILE, row * TILE, (col + 1) * TILE, (row + 1) * TILE)
    return atlas.crop(box).convert("RGBA")


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    pkg_root = os.path.dirname(here)
    cache = os.path.join(here, ".cache")
    os.makedirs(cache, exist_ok=True)
    atlas_path = fetch_atlas(os.path.join(cache, "oneko.gif"))

    atlas = Image.open(atlas_path).convert("RGBA")
    if atlas.size != (256, 128):
        print(
            f"warning: atlas size is {atlas.size}, expected (256, 128) — "
            "frame coordinates assume the canonical oneko atlas",
            file=sys.stderr,
        )

    cropped: dict[tuple[str, int], Image.Image] = {}
    for key, coords in ONEKO_SPRITES.items():
        for i, (cn, rn) in enumerate(coords):
            cropped[(key, i)] = crop_tile(atlas, cn, rn)

    sprites_root = os.path.join(
        pkg_root, "Sources", "AOPet", "Resources", "sprites"
    )

    for set_name in BUNDLED_SETS:
        out_dir = os.path.join(sprites_root, set_name)
        os.makedirs(out_dir, exist_ok=True)
        for fname in os.listdir(out_dir):
            if fname.endswith(".png"):
                os.remove(os.path.join(out_dir, fname))

        tint = SET_TINTS.get(set_name, (1.0, 1.0, 1.0))
        for mood, frame_specs in MOOD_TO_FRAMES.items():
            for i, (oneko_key, oneko_idx) in enumerate(frame_specs):
                tile = cropped[(oneko_key, oneko_idx)]
                tinted = apply_tint(tile, tint)
                tinted.save(os.path.join(out_dir, f"{mood}_{i}.png"))
        total = sum(len(v) for v in MOOD_TO_FRAMES.values())
        print(f"wrote {set_name}: {total} frames")

    return 0


def apply_tint(image: Image.Image, tint: tuple[float, float, float]) -> Image.Image:
    """Multiply RGB channels of non-transparent pixels by `tint`. Alpha is
    preserved, so the silhouette stays identical and only the colour shifts.
    Returns the input unchanged if tint is identity."""
    if tint == (1.0, 1.0, 1.0):
        return image.copy()
    pixels = image.load()
    out = Image.new("RGBA", image.size)
    out_pixels = out.load()
    for y in range(image.size[1]):
        for x in range(image.size[0]):
            r, g, b, a = pixels[x, y]
            if a == 0:
                out_pixels[x, y] = (0, 0, 0, 0)
                continue
            rr = min(255, max(0, int(r * tint[0])))
            gg = min(255, max(0, int(g * tint[1])))
            bb = min(255, max(0, int(b * tint[2])))
            out_pixels[x, y] = (rr, gg, bb, a)
    return out


if __name__ == "__main__":
    raise SystemExit(main())
