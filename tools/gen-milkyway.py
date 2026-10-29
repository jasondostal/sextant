#!/usr/bin/env python3
"""gen-milkyway.py — the Milky Way texture: ESO's all-sky panorama (eso0932a,
ESO/S. Brunier, CC BY 4.0) with the stars taken out, as a greyscale glow the
sky shader tints lavender like Star Walk's.

Input:  ~/.cache/ducktyping-sky/eso/eso0932a.jpg — 6000×3000 equirectangular in
        galactic coordinates, l = 0 at the centre and increasing to the LEFT,
        b = +90 at the top (checked against the LMC at l 280.5°, b −32.9°).
Output: Sky/Resources/milkyway.png, 2048×1024 8-bit grey, same mapping.

Stars are drawn by the app from the catalog, so they are removed here: a
median filter wipes point sources while keeping the clouds and dust lanes.

The panorama is not exactly in galactic coordinates: it's rotated 3.7° (the
Pleiades glow sat 5° off the cluster). ROTATION, from tools/fit-milkyway.py
(27 bright stars, residual median 0.09°), maps image directions onto true
ones; the output is resampled through it so the shader can stay a plain
galactic lookup.
"""
import os
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.expanduser('~/.cache/ducktyping-sky/eso/eso0932a.jpg')
OUT = os.path.join(ROOT, 'Sky', 'Resources', 'milkyway.png')

ROTATION = np.array([[0.99807309, -0.05472308, 0.02924866],
                     [0.05522896, 0.99833276, -0.0167768],
                     [-0.02828182, 0.01835985, 0.99943137]])   # true ≈ ROTATION · image

im = Image.open(SRC).convert('L').resize((3072, 1536), Image.LANCZOS)
im = im.filter(ImageFilter.MedianFilter(7)).filter(ImageFilter.MedianFilter(5))
src = np.asarray(im).astype(np.float32)
SH, SW = src.shape

# for each output pixel (true l, b): where the panorama shows that direction
OW, OH = 2048, 1024
u, v = np.meshgrid((np.arange(OW) + 0.5) / OW, (np.arange(OH) + 0.5) / OH)
l, b = (0.5 - u) * 2 * np.pi, (0.5 - v) * np.pi
t = np.stack([np.cos(b) * np.cos(l), np.cos(b) * np.sin(l), np.sin(b)], axis=-1)
i = t @ ROTATION                                   # rows: ROTATIONᵀ · t
il, ib = np.arctan2(i[..., 1], i[..., 0]), np.arcsin(np.clip(i[..., 2], -1, 1))
x = ((0.5 - il / (2 * np.pi)) * SW - 0.5) % SW
y = np.clip((0.5 - ib / np.pi) * SH - 0.5, 0, SH - 1.001)
x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
fx, fy = x - x0, y - y0
x1 = (x0 + 1) % SW
a = (src[y0, x0] * (1 - fx) * (1 - fy) + src[y0, x1] * fx * (1 - fy) +
     src[y0 + 1, x0] * (1 - fx) * fy + src[y0 + 1, x1] * fx * fy)
a = np.asarray(Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))).astype(np.float32)
black = np.percentile(a, 35)           # the empty sky away from the band
white = np.percentile(a, 99.7)
a = np.clip((a - black) / (white - black), 0, 1) ** 0.85
Image.fromarray((a * 255).round().astype(np.uint8)).save(OUT, optimize=True)
print(OUT, os.path.getsize(OUT), 'bytes')
