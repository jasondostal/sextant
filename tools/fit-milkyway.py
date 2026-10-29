#!/usr/bin/env python3
"""fit-milkyway.py — measure how ESO's panorama (eso0932a) is rotated against
true galactic coordinates, using bright stars as control points.

Each star's catalog position (stars.bin, the gated HYG catalog) is predicted in
the image; its actual peak is found nearby; a rotation is fitted (Kabsch) that
maps where the image puts things onto where they are. Prints the rotation as a
row-major 3×3 for gen-milkyway.py, and the residuals before/after.
"""
import json, math, os, struct
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, 'SkyCore', 'Sources', 'SkyCore', 'Resources')
SRC = os.path.expanduser('~/.cache/ducktyping-sky/eso/eso0932a.jpg')
NAMES = ['Sirius', 'Canopus', 'Arcturus', 'Vega', 'Capella', 'Rigel', 'Procyon', 'Achernar', 'Betelgeuse',
         'Altair', 'Aldebaran', 'Antares', 'Spica', 'Pollux', 'Fomalhaut', 'Deneb', 'Regulus', 'Castor',
         'Shaula', 'Bellatrix', 'Elnath', 'Alnilam', 'Alioth', 'Dubhe', 'Mirfak', 'Peacock', 'Alhena', 'Polaris']
EQ_TO_GAL = np.array([[-0.0548755604, -0.8734370902, -0.4838350155],
                      [0.4941094279, -0.4448296300, 0.7469822445],
                      [-0.8676661490, -0.1980763734, 0.4559837762]])
W, H = 6000, 3000


def vec(l, b):
    l, b = math.radians(l), math.radians(b)
    return np.array([math.cos(b) * math.cos(l), math.cos(b) * math.sin(l), math.sin(b)])


def lb(v):
    return math.degrees(math.atan2(v[1], v[0])), math.degrees(math.asin(max(-1, min(1, v[2]))))


def pix(l, b):
    return (0.5 - l / 360) * W, (0.5 - b / 180) * H


def unpix(x, y):
    return (0.5 - x / W) * 360, (0.5 - y / H) * 180


data = json.load(open(os.path.join(RES, 'sky-data.json')))
idx = {n: i for i, n in data['starNames']}
raw = open(os.path.join(RES, 'stars.bin'), 'rb').read()
img = np.asarray(Image.open(SRC).convert('L')).astype(float)

stars = []
for n in NAMES:
    ra16, dec16, _, _ = struct.unpack_from('<Hhhh', raw, idx[n] * 8)
    ra, dec = math.radians(ra16 / 65535 * 24 * 15), math.radians(dec16 / 32767 * 90)
    g = EQ_TO_GAL @ np.array([math.cos(dec) * math.cos(ra), math.cos(dec) * math.sin(ra), math.sin(dec)])
    if abs(lb(g)[1]) < 70:            # equirectangular smears the poles
        stars.append((n, g))


def peak(g, R, r):
    """Where the image actually shows the star whose true direction is g,
    searching r px around where rotation R (true ≈ R·image) predicts it."""
    x, y = pix(*lb(R.T @ g))
    x0, y0 = int(x) - r, int(y) - r
    if x0 < 0 or y0 < 0 or x0 + 2 * r > W or y0 + 2 * r > H:
        return None
    sub = img[y0:y0 + 2 * r, x0:x0 + 2 * r]
    sm = np.asarray(Image.fromarray(sub.astype(np.uint8)).filter(ImageFilter.GaussianBlur(2))).astype(float)
    yy, xx = np.unravel_index(sm.argmax(), sm.shape)
    return vec(*unpix(x0 + xx, y0 + yy))


def kabsch(A, B):
    U, _, Vt = np.linalg.svd(A.T @ B)
    d = np.sign(np.linalg.det(U @ Vt))
    return (U @ np.diag([1, 1, d]) @ Vt).T     # B ≈ R @ A


def err(R, a, b):
    return math.degrees(math.acos(min(1, (R @ a) @ b)))


R = np.eye(3)
for radius in (110, 60, 35, 20, 12):
    pairs = [(peak(g, R, radius), g, n) for n, g in stars]
    pairs = [p for p in pairs if p[0] is not None]
    e = [err(R, a, b) for a, b, _ in pairs]
    keep = [p for p, x in zip(pairs, e) if x <= max(3 * np.median(e), 0.15)] if radius < 110 else pairs
    R = kabsch(np.array([p[0] for p in keep]), np.array([p[1] for p in keep]))
    res = [err(R, a, b) for a, b, _ in keep]
    print(f'search {radius:3d}px: {len(keep)}/{len(pairs)} stars, residual median {np.median(res):.3f}° max {max(res):.3f}°')
print('rotation angle %.2f°' % math.degrees(math.acos((np.trace(R) - 1) / 2)))
print(json.dumps(R.round(8).tolist()))
