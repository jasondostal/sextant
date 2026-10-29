#!/usr/bin/env python3
"""gen-satmags.py — standard magnitudes for every object in orbit, bundled with
SkyCore so the phone only has to download orbits, not the catalogue.

Standard magnitude = how bright the object would be at 1,000 km, half lit.
From CelesTrak's SATCAT (~/.cache/ducktyping-sky/satcat.csv): estimated from
radar cross-section where there is one, 5.6 − 2.5·log10(RCS m²), clamped to
1.5…9; otherwise by type (rocket bodies are big and bright, debris small).
The well-known ones and whole families are overridden in Satellites.swift.

satmags.bin: sorted by NORAD id, 6 bytes each, little-endian:
  uint32 id, int16 standard magnitude × 100.
"""
import csv, math, os, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.expanduser('~/.cache/ducktyping-sky/satcat.csv')
OUT = os.path.join(ROOT, 'SkyCore', 'Sources', 'SkyCore', 'Resources', 'satmags.bin')
BY_TYPE = {'R/B': 4.0, 'PAY': 6.5, 'DEB': 8.0, 'UNK': 7.5}

rows = []
with open(SRC, newline='') as f:
    for r in csv.DictReader(f):
        if r['DECAY_DATE'] or r['ORBIT_CENTER'] != 'EA':
            continue
        try:
            rcs = float(r['RCS']) if r['RCS'] else 0
        except ValueError:
            rcs = 0
        mag = max(1.5, min(9.0, 5.6 - 2.5 * math.log10(rcs))) if rcs > 0 else BY_TYPE.get(r['OBJECT_TYPE'], 7.5)
        rows.append((int(r['NORAD_CAT_ID']), mag))
rows.sort()
with open(OUT, 'wb') as f:
    for nid, mag in rows:
        f.write(struct.pack('<Ih', nid, round(mag * 100)))
print(f'{len(rows)} objects, {os.path.getsize(OUT)} bytes -> {OUT}')
