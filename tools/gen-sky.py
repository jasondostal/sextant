#!/usr/bin/env python3
"""gen-sky.py — the fixed sky for SkyCore: stars, constellations, the Milky Way.
Writes SkyCore/Sources/SkyCore/Resources/stars.bin and sky-data.json.

Sources, cached in ~/.cache/ducktyping-sky:
  hyg_v44.csv  HYG database v4.4 (astronexus, CC BY-SA 4.0, codeberg.org/astronexus/hyg):
               stars to mag 8, about what binoculars show under a dark sky.
               Positions are moved by proper motion from J2000 to EPOCH, so no
               star is more than a few arcseconds off for years either side.
  d3c/         d3-celestial 0.7.35 data (Olaf Frohn, BSD-3): constellation
               lines and names, and the Milky Way outline (mw.json, five
               nested brightness levels).

stars.bin is 8 bytes a star, little-endian, sorted brightest first so the page
can stop reading at whatever magnitude the zoom calls for:
  uint16 RA (0..65535 = 0..24h), int16 Dec (±32767 = ±90°),
  int16 magnitude × 100, int16 B−V colour index × 1000.

d3c/ is optional: without it the constellation and Milky Way data already in
sky-data.json are kept and only the stars are rebuilt.

The Milky Way is shipped as points, not polygons: a ~2° grid over the sphere,
each point tagged with the brightest outline level it falls inside. The page
draws each one as a soft glow, which survives any projection, where a polygon
crossing the edge of the view would not. Inside/outside is decided on the
sphere (crossings of the arc to the nearer galactic pole, which is outside
every level), because the band wraps all the way around the sky.
"""
import csv, json, math, os, struct
import numpy as np

CACHE = os.path.expanduser('~/.cache/ducktyping-sky')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'SkyCore', 'Sources', 'SkyCore', 'Resources')
MAG_LIMIT = 8.0
NAME_LIMIT = 6.5
EPOCH = 2028.0   # Julian year the packed positions are for


def unit(ra_deg, dec_deg):
    ra, dec = np.radians(ra_deg), np.radians(dec_deg)
    return np.stack([np.cos(dec) * np.cos(ra), np.cos(dec) * np.sin(ra), np.sin(dec)], axis=-1)


def stars():
    rows = []
    years = EPOCH - 2000.0
    with open(os.path.join(CACHE, 'hyg_v44.csv'), newline='') as f:
        for r in csv.DictReader(f):
            if r['id'] == '0' or not r['mag']:
                continue
            mag = float(r['mag'])
            if mag > MAG_LIMIT:
                continue
            ci = float(r['ci']) if r['ci'] else 0.6
            ra, dec = float(r['ra']), float(r['dec'])
            # pmra is μα·cos δ (Hipparcos convention), both in mas/yr
            pmra, pmdec = float(r['pmra'] or 0), float(r['pmdec'] or 0)
            cosd = max(math.cos(math.radians(dec)), 1e-6)
            ra = (ra + pmra * years / 3.6e6 / cosd / 15) % 24
            dec = dec + pmdec * years / 3.6e6
            rows.append((mag, ra, dec, ci, r['proper'], r['bayer'], r['con']))
    rows.sort(key=lambda x: x[0])
    buf = bytearray()
    names = []
    for i, (mag, ra, dec, ci, proper, bayer, con) in enumerate(rows):
        buf += struct.pack('<Hhhh', round(ra / 24 * 65535) % 65536, round(dec / 90 * 32767),
                           round(mag * 100), round(max(-0.5, min(2.5, ci)) * 1000))
        if mag <= NAME_LIMIT and proper:
            names.append([i, proper])
    return bytes(buf), names, len(rows)


def constellations():
    lines = json.load(open(os.path.join(CACHE, 'd3c', 'constellations.lines.json')))
    names = json.load(open(os.path.join(CACHE, 'd3c', 'constellations.json')))
    out_lines = []
    for f in lines['features']:
        for seg in f['geometry']['coordinates']:
            flat = []
            for lon, lat in seg:
                flat += [round(lon % 360, 3), round(lat, 3)]
            out_lines.append(flat)
    out_names = []
    for f in names['features']:
        lon, lat = f['geometry']['coordinates']
        out_names.append([f['properties']['name'], round(lon % 360, 2), round(lat, 2), int(f['properties']['rank'])])
    return out_lines, out_names


# galactic north pole, J2000
NGP = unit(192.85948, 27.12825)


def milky_way():
    mw = json.load(open(os.path.join(CACHE, 'd3c', 'mw.json')))
    n = 10000
    k = np.arange(n) + 0.5
    dec = np.degrees(np.arcsin(1 - 2 * k / n))
    ra = np.degrees(np.pi * (1 + 5 ** 0.5) * k) % 360
    p = unit(ra, dec)
    b = np.degrees(np.arcsin(p @ NGP))
    keep = np.abs(b) < 45
    p, ra, dec, b = p[keep], ra[keep], dec[keep], b[keep]
    ref = np.where((b > 0)[:, None], NGP, -NGP)          # the nearer pole
    level = np.zeros(len(p), dtype=int)
    for lv, feat in enumerate(mw['features'], start=1):
        inside = np.zeros(len(p), dtype=bool)
        for poly in feat['geometry']['coordinates']:
            for ring in poly:
                v = unit(np.array([c[0] for c in ring]) % 360, np.array([c[1] for c in ring]))
                a, c = v[:-1], v[1:]
                for s in range(0, len(p), 1500):
                    P, Q = p[s:s + 1500, None, :], ref[s:s + 1500, None, :]
                    nPQ = np.cross(P, Q)                     # plane of the arc point→pole
                    nAC = np.cross(a, c)[None]               # plane of each ring edge
                    s1 = np.sign(np.sum(nPQ * a[None], -1)) != np.sign(np.sum(nPQ * c[None], -1))
                    s2 = np.sign(np.sum(nAC * P, -1)) != np.sign(np.sum(nAC * Q, -1))
                    same = np.sum((P + Q) * (a + c)[None], -1) > 0
                    inside[s:s + 1500] ^= (np.sum(s1 & s2 & same, axis=1) % 2).astype(bool)
        level[inside] = lv
    sel = level > 0
    return [[round(float(r), 2), round(float(d), 2), int(l)] for r, d, l in zip(ra[sel], dec[sel], level[sel])]


def main():
    os.makedirs(OUT, exist_ok=True)
    buf, names, count = stars()
    with open(os.path.join(OUT, 'stars.bin'), 'wb') as f:
        f.write(buf)
    if os.path.isdir(os.path.join(CACHE, 'd3c')):
        lines, cnames = constellations()
        mw = milky_way()
    else:
        old = json.load(open(os.path.join(OUT, 'sky-data.json')))
        lines, cnames, mw = old['lines'], old['constellations'], old['milkyWay']
    data = {'stars': count, 'epoch': EPOCH, 'starNames': names, 'lines': lines, 'constellations': cnames, 'milkyWay': mw}
    with open(os.path.join(OUT, 'sky-data.json'), 'w') as f:
        json.dump(data, f, separators=(',', ':'), ensure_ascii=False)
    print(f'{count} stars ({len(buf)} bytes), {len(names)} named, {len(lines)} line segments, '
          f'{len(cnames)} constellations, {len(mw)} Milky Way points')


if __name__ == '__main__':
    main()
