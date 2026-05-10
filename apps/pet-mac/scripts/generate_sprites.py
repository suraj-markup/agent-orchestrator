#!/usr/bin/env python3
"""Generate AOPet sprite frames from two upstream sources.

oneko set
---------
Source: https://github.com/adryd325/oneko.js (MIT). The bundled atlas is
256x128, organized as an 8 (col) x 4 (row) grid of 32x32 frames. The
mapping below is taken verbatim from oneko.js's `spriteSets` table.

dog set
-------
Source: https://github.com/tie/oneko (a Git mirror of the classic
xneko/oneko Unix program by Masayuki Koba / Tatsuya Kato et al.). The
program — and its bundled XBM bitmaps including the dog — has been
distributed as **public domain** for ~35 years, corroborated by
mdonoughe/neko-mac (Unlicense) which states it's "based off the public
domain Oneko code". Each pose is an X11 bitmap (XBM) of 32x32 pixels;
this script downloads them, parses the bitmap data, renders to PNG with
a foreground colour, and maps the oneko-style pose names onto AO's
PetMood frame layout.

Output: apps/pet-mac/Sources/AOPet/Resources/sprites/<set>/<mood>_<n>.png
"""
from __future__ import annotations
import os
import re
import sys
import urllib.request
from PIL import Image

TILE = 32

# ── oneko (cat) ───────────────────────────────────────────────────────────
# adryd325/oneko.js MIT atlas.
ONEKO_ATLAS_URL = "https://raw.githubusercontent.com/adryd325/oneko.js/main/oneko.gif"

# Verbatim from oneko.js. Coordinates are [col_neg, row_neg] where the
# CSS background-position is `${col_neg*32}px ${row_neg*32}px`, i.e. the
# tile at (col=-col_neg, row=-row_neg).
ONEKO_SPRITES = {
    "idle":         [[-3, -3]],
    "alert":        [[-7, -3]],
    "scratchSelf":  [[-5,  0], [-6,  0], [-7,  0]],
    "tired":        [[-3, -2]],
    "sleeping":     [[-2,  0], [-2, -1]],
    # 8 walking directions × 2 frames each. Directions follow compass
    # bearings (N = up, E = right). Used for the wander animation.
    "N":  [[-1, -2], [-1, -3]],
    "NE": [[ 0, -2], [ 0, -3]],
    "E":  [[-3,  0], [-3, -1]],
    "SE": [[-5, -1], [-5, -2]],
    "S":  [[-6, -3], [-7, -2]],
    "SW": [[-5, -3], [-6, -1]],
    "W":  [[-4, -2], [-4, -3]],
    "NW": [[-1,  0], [-1, -1]],
}

ONEKO_MOOD_TO_FRAMES = {
    "sleeping": [("sleeping", 0), ("sleeping", 1)],
    "working":  [("E", 0),        ("E", 1)],
    "happy":    [("idle", 0),     ("tired", 0)],
    "sad":      [("alert", 0),    ("idle", 0)],
    "alert":    [("scratchSelf", 0), ("scratchSelf", 1), ("scratchSelf", 2)],
}

# Compass direction → oneko sprite-key for the walk animation.
ONEKO_WALK_DIRS = {
    "n":  "N",
    "ne": "NE",
    "e":  "E",
    "se": "SE",
    "s":  "S",
    "sw": "SW",
    "w":  "W",
    "nw": "NW",
}

# ── dog (XBM) ─────────────────────────────────────────────────────────────
# tie/oneko bitmaps mirror. Each entry is the XBM filename relative to
# bitmaps/dog/. 32x32, 1bpp, LSB-first.
DOG_XBM_BASE = "https://raw.githubusercontent.com/tie/oneko/master/bitmaps/dog"
DOG_XBM_FILES = {
    "sleep1":  "sleep1_dog.xbm",
    "sleep2":  "sleep2_dog.xbm",
    "mati2":   "mati2_dog.xbm",    # standing/idle blink frame
    "mati3":   "mati3_dog.xbm",
    "awake":   "awake_dog.xbm",    # surprised pose
    "kaki1":   "kaki1_dog.xbm",    # scratching itself, frames
    "kaki2":   "kaki2_dog.xbm",
    "jare2":   "jare2_dog.xbm",    # third scratching pose
    # 8 walking directions × 2 frames. The xneko `dw` prefix means
    # "diagonal walk" (south-east/south-west).
    "right1":  "right1_dog.xbm",
    "right2":  "right2_dog.xbm",
    "left1":   "left1_dog.xbm",
    "left2":   "left2_dog.xbm",
    "up1":     "up1_dog.xbm",
    "up2":     "up2_dog.xbm",
    "down1":   "down1_dog.xbm",
    "down2":   "down2_dog.xbm",
    "upright1":  "upright1_dog.xbm",
    "upright2":  "upright2_dog.xbm",
    "upleft1":   "upleft1_dog.xbm",
    "upleft2":   "upleft2_dog.xbm",
    "dwright1":  "dwright1_dog.xbm",
    "dwright2":  "dwright2_dog.xbm",
    "dwleft1":   "dwleft1_dog.xbm",
    "dwleft2":   "dwleft2_dog.xbm",
}

DOG_MOOD_TO_FRAMES = {
    "sleeping": [("sleep1",), ("sleep2",)],
    "working":  [("right1",), ("right2",)],   # walking east
    "happy":    [("mati2",),  ("mati3",)],    # idle blink
    "sad":      [("awake",),  ("mati2",)],    # surprised + neutral; gets red ! overlay
    "alert":    [("kaki1",),  ("kaki2",), ("jare2",)],
}

# Compass direction → (frame0_pose, frame1_pose) for the dog walk.
# `dw` prefix in upstream xneko = "diagonal walk" (south-bound).
DOG_WALK_DIRS = {
    "n":  ("up1",       "up2"),
    "ne": ("upright1",  "upright2"),
    "e":  ("right1",    "right2"),
    "se": ("dwright1",  "dwright2"),
    "s":  ("down1",     "down2"),
    "sw": ("dwleft1",   "dwleft2"),
    "w":  ("left1",     "left2"),
    "nw": ("upleft1",   "upleft2"),
}

# RGB foreground colour the XBM bits render to. Alpha is per-bit (1=opaque,
# 0=transparent), matching the original oneko convention. The dog reads as a
# warm brown silhouette so it's visually distinct from oneko's white cat.
DOG_FG = (102, 70, 38)

BUNDLED_SETS = ["oneko", "dog"]


# ── Fetch / cache ─────────────────────────────────────────────────────────

def fetch(url: str, dest: str) -> str:
    if os.path.exists(dest):
        return dest
    print(f"Fetching {url} -> {dest}")
    urllib.request.urlretrieve(url, dest)
    return dest


# ── oneko cropping ────────────────────────────────────────────────────────

def crop_tile(atlas: Image.Image, col_neg: int, row_neg: int) -> Image.Image:
    col = -col_neg
    row = -row_neg
    box = (col * TILE, row * TILE, (col + 1) * TILE, (row + 1) * TILE)
    return atlas.crop(box).convert("RGBA")


# ── XBM parsing ───────────────────────────────────────────────────────────

def parse_xbm(content: str) -> tuple[int, int, list[int]]:
    width = int(re.search(r"#define\s+\w+_width\s+(\d+)", content).group(1))
    height = int(re.search(r"#define\s+\w+_height\s+(\d+)", content).group(1))
    body = re.search(r"\{([^}]+)\}", content, re.DOTALL).group(1)
    bytes_ = [int(b.strip(), 0) for b in body.split(",") if b.strip()]
    return width, height, bytes_


def xbm_to_image(width: int, height: int, byte_vals: list[int],
                 fg: tuple[int, int, int]) -> Image.Image:
    """Render an X11 XBM (LSB-first per row) to RGBA. Set bits → fg/opaque,
    clear bits → transparent."""
    bytes_per_row = (width + 7) // 8
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    px = img.load()
    for y in range(height):
        for x in range(width):
            byte_idx = y * bytes_per_row + (x // 8)
            bit_idx = x % 8
            if byte_idx >= len(byte_vals):
                continue
            if (byte_vals[byte_idx] >> bit_idx) & 1:
                px[x, y] = (*fg, 255)
    return img


# ── Pipeline ──────────────────────────────────────────────────────────────

def write_oneko(cache: str, out_dir: str) -> None:
    atlas_path = fetch(ONEKO_ATLAS_URL, os.path.join(cache, "oneko.gif"))
    atlas = Image.open(atlas_path).convert("RGBA")
    if atlas.size != (256, 128):
        print(
            f"warning: oneko atlas is {atlas.size}, expected (256, 128) — "
            "coords assume the canonical layout",
            file=sys.stderr,
        )
    cropped = {}
    for key, coords in ONEKO_SPRITES.items():
        for i, (cn, rn) in enumerate(coords):
            cropped[(key, i)] = crop_tile(atlas, cn, rn)
    for mood, specs in ONEKO_MOOD_TO_FRAMES.items():
        for i, (key, idx) in enumerate(specs):
            cropped[(key, idx)].save(
                os.path.join(out_dir, f"{mood}_{i}.png")
            )
    # Walk frames per direction, used by the wander animation.
    for dir_name, sprite_key in ONEKO_WALK_DIRS.items():
        for i in range(2):
            cropped[(sprite_key, i)].save(
                os.path.join(out_dir, f"walk_{dir_name}_{i}.png")
            )


def write_dog(cache: str, out_dir: str) -> None:
    poses: dict[str, Image.Image] = {}
    for pose, fname in DOG_XBM_FILES.items():
        local = os.path.join(cache, f"dog_{fname}")
        fetch(f"{DOG_XBM_BASE}/{fname}", local)
        with open(local, "r") as f:
            w, h, bs = parse_xbm(f.read())
        poses[pose] = xbm_to_image(w, h, bs, DOG_FG)
    for mood, specs in DOG_MOOD_TO_FRAMES.items():
        for i, (pose,) in enumerate(specs):
            poses[pose].save(os.path.join(out_dir, f"{mood}_{i}.png"))
    # Walk frames per direction.
    for dir_name, (frame0, frame1) in DOG_WALK_DIRS.items():
        poses[frame0].save(os.path.join(out_dir, f"walk_{dir_name}_0.png"))
        poses[frame1].save(os.path.join(out_dir, f"walk_{dir_name}_1.png"))


def reset_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)
    for fname in os.listdir(path):
        if fname.endswith(".png"):
            os.remove(os.path.join(path, fname))


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    pkg_root = os.path.dirname(here)
    cache = os.path.join(here, ".cache")
    os.makedirs(cache, exist_ok=True)
    sprites_root = os.path.join(
        pkg_root, "Sources", "AOPet", "Resources", "sprites"
    )

    # Drop any leftover sets that aren't bundled any more.
    if os.path.isdir(sprites_root):
        for entry in os.listdir(sprites_root):
            full = os.path.join(sprites_root, entry)
            if os.path.isdir(full) and entry not in BUNDLED_SETS:
                for fname in os.listdir(full):
                    os.remove(os.path.join(full, fname))
                os.rmdir(full)

    for set_name in BUNDLED_SETS:
        out_dir = os.path.join(sprites_root, set_name)
        reset_dir(out_dir)
        if set_name == "oneko":
            write_oneko(cache, out_dir)
        elif set_name == "dog":
            write_dog(cache, out_dir)
        n = len(os.listdir(out_dir))
        print(f"wrote {set_name}: {n} frames")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
