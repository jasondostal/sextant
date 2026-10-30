#!/usr/bin/env python3
"""gen-icon.py: draws Sky's app icon (1024 px, iOS masks the corners): Star
Walk's night blue, a few sparkling stars, and a satellite with the app's cyan
motion trail. Drawn at 4x and downsampled."""
import json, math, os, random
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'Sky', 'Assets.xcassets', 'AppIcon.appiconset')
S = 4096

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

img = Image.new('RGB', (S, S))
px = img.load()
top, bottom = (6, 2, 74), (0, 6, 40)
for y in range(S):
    c = lerp(top, bottom, y / S)
    for x in range(0, S):
        px[x, y] = c
d = ImageDraw.Draw(img)

# Milky Way: a soft lavender band across the corner
band = Image.new('L', (S, S))
bd = ImageDraw.Draw(band)
for i in range(60):
    w = S * 0.32 * (1 - i / 60)
    bd.line([(-S * 0.1, S * 1.05), (S * 1.1, S * 0.05)], fill=int(3 + i * 1.1), width=int(w))
band = band.filter(ImageFilter.GaussianBlur(S * 0.03))
img = Image.composite(Image.new('RGB', (S, S), (120, 105, 190)), img, band)
d = ImageDraw.Draw(img)

random.seed(7)
for _ in range(260):
    x, y, r = random.random() * S, random.random() * S, random.choice([3, 4, 5, 6, 8])
    v = random.randint(120, 230)
    d.ellipse([x - r, y - r, x + r, y + r], fill=(v, v, min(255, v + 20)))

def sparkle(x, y, r, color):
    glow = Image.new('L', (S, S))
    g = ImageDraw.Draw(glow)
    g.ellipse([x - r * 2.2, y - r * 2.2, x + r * 2.2, y + r * 2.2], fill=110)
    glow = glow.filter(ImageFilter.GaussianBlur(r * 1.2))
    base = Image.composite(Image.new('RGB', (S, S), color), img, glow)
    dd = ImageDraw.Draw(base)
    for dx, dy in [(1, 0), (0, 1)]:
        dd.polygon([(x - dx * r * 6, y - dy * r * 6), (x + dy * r * 0.35, y + dx * r * 0.35),
                    (x + dx * r * 6, y + dy * r * 6), (x - dy * r * 0.35, y - dx * r * 0.35)], fill=color)
    dd.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 245))
    return base

img = sparkle(S * 0.72, S * 0.26, 34, (255, 250, 215))
img = sparkle(S * 0.24, S * 0.40, 22, (220, 230, 255))
img = sparkle(S * 0.82, S * 0.70, 16, (255, 235, 200))
d = ImageDraw.Draw(img)

# the satellite and its fading trail, lower left to upper right
x0, y0, x1, y1 = S * 0.16, S * 0.86, S * 0.58, S * 0.56
n = 80
for i in range(n):
    t0, t1 = i / n, (i + 1) / n
    a = t1 ** 1.6
    c = lerp((0, 6, 40), (78, 203, 207), a)
    d.line([(x0 + (x1 - x0) * t0, y0 + (y1 - y0) * t0), (x0 + (x1 - x0) * t1, y0 + (y1 - y0) * t1)],
           fill=c, width=int(30 + 34 * a))
halo = Image.new('L', (S, S))
ImageDraw.Draw(halo).ellipse([x1 - 150, y1 - 150, x1 + 150, y1 + 150], fill=150)
halo = halo.filter(ImageFilter.GaussianBlur(70))
img = Image.composite(Image.new('RGB', (S, S), (140, 230, 235)), img, halo)
ImageDraw.Draw(img).ellipse([x1 - 62, y1 - 62, x1 + 62, y1 + 62], fill=(255, 255, 255))

img.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, 'icon.png'))
json.dump({'images': [{'filename': 'icon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}],
           'info': {'author': 'xcode', 'version': 1}}, open(os.path.join(OUT, 'Contents.json'), 'w'), indent=2)
json.dump({'info': {'author': 'xcode', 'version': 1}},
          open(os.path.join(os.path.dirname(OUT), 'Contents.json'), 'w'), indent=2)
print(os.path.join(OUT, 'icon.png'))
