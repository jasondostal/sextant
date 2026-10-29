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
"""
import os
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.expanduser('~/.cache/ducktyping-sky/eso/eso0932a.jpg')
OUT = os.path.join(ROOT, 'Sky', 'Resources', 'milkyway.png')

im = Image.open(SRC).convert('L').resize((3072, 1536), Image.LANCZOS)
im = im.filter(ImageFilter.MedianFilter(7)).filter(ImageFilter.MedianFilter(5))
im = im.resize((2048, 1024), Image.LANCZOS).filter(ImageFilter.GaussianBlur(1.2))
a = np.asarray(im).astype(np.float32)
black = np.percentile(a, 35)           # the empty sky away from the band
white = np.percentile(a, 99.7)
a = np.clip((a - black) / (white - black), 0, 1) ** 0.85
Image.fromarray((a * 255).round().astype(np.uint8)).save(OUT, optimize=True)
print(OUT, os.path.getsize(OUT), 'bytes')
