#!/usr/bin/env python3
"""sky-sats.py — the satellites for /playground/sky/.

Writes sky-sats.json (default public/sky-sats.json, or the path given as the
first argument) from CelesTrak: orbital elements in OMM form (TLEs ran out of
catalog numbers) for the active catalog plus the "visual" group, which adds
the bright rocket bodies the active list leaves out. Standard library only, so
the same script runs at build time on CORTEX and from cron on UTIL, where it
rewrites the deployed copy in place (the page reads it same-origin; the site's
CSP allows nothing else):

  15 9 * * * python3 /home/jdostal/sky/sky-sats.py \
      /home/jdostal/docker/swag/config/www/ducktyping/sky-sats.json

Brightness. Each object gets a standard magnitude: how bright it would be at
1,000 km, half lit. A handful of famous ones are known; whole families
(Starlink, OneWeb) get their measured typical value; everything else is
estimated from its radar cross-section in CelesTrak's catalog, or from its
type. Objects that can't reach magnitude 7.5 even overhead at perigee are
dropped, which takes out the geostationary belt and the small stuff.

A failed fetch leaves the previous file alone.
"""
import csv, io, json, math, os, sys, tempfile, time, urllib.request
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'public', 'sky-sats.json')
CACHE = os.path.expanduser('~/.cache/ducktyping-sky/satcat.csv')
GP = 'https://celestrak.org/NORAD/elements/gp.php?GROUP=%s&FORMAT=json'
SATCAT = 'https://celestrak.org/pub/satcat.csv'
FAINTEST = 7.5          # the brightness slider's far end
MU, RE = 398600.4418, 6378.137

KNOWN = {               # NORAD id: standard magnitude
    25544: -1.8,        # ISS
    48274: -0.6,        # Tiangong (CSS)
    20580: 2.2,         # Hubble
}
FAMILY = [              # name prefix: typical standard magnitude
    ('STARLINK', 6.0),
    ('ONEWEB', 7.5),
    ('KUIPER', 6.0),
]


def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'ducktyping.dev sky'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def gp(group):
    """One CelesTrak group, cached. CelesTrak answers 403 when the same data
    is asked for again before it has changed (about every two hours), so a
    rerun falls back to the copy from the last fetch if it's under a day old."""
    path = os.path.join(os.path.dirname(CACHE), f'gp-{group}.json')
    try:
        data = fetch(GP % group)
        with open(path, 'wb') as f:
            f.write(data)
    except Exception:
        if not os.path.exists(path) or time.time() - os.path.getmtime(path) > 86400:
            raise
        data = open(path, 'rb').read()
    return json.loads(data)


def satcat():
    """RCS and object type by NORAD id. The catalog barely changes, so it's
    refetched weekly."""
    if not os.path.exists(CACHE) or time.time() - os.path.getmtime(CACHE) > 7 * 86400:
        data = fetch(SATCAT)
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        with open(CACHE, 'wb') as f:
            f.write(data)
    out = {}
    with open(CACHE, newline='') as f:
        for row in csv.DictReader(f):
            try:
                rcs = float(row['RCS']) if row['RCS'] else None
            except ValueError:
                rcs = None
            out[int(row['NORAD_CAT_ID'])] = (row['OBJECT_TYPE'], rcs)
    return out


def std_mag(o, cat, visual):
    nid, name = o['NORAD_CAT_ID'], o['OBJECT_NAME'].upper()
    if nid in KNOWN:
        return KNOWN[nid], False
    for prefix, m in FAMILY:
        if name.startswith(prefix):
            return m, True
    kind, rcs = cat.get(nid, ('PAY', None))
    if rcs and rcs > 0:
        return max(1.5, min(9.0, 5.6 - 2.5 * math.log10(rcs))), True
    if nid in visual:
        return 3.5, True
    return (4.0 if kind == 'R/B' else 6.5), True


def main():
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    active = gp('active')
    vis = gp('visual')
    visual = {o['NORAD_CAT_ID'] for o in vis}
    cat = satcat()
    seen, sats = set(), []
    for o in vis + active:
        nid = o['NORAD_CAT_ID']
        if nid in seen:
            continue
        seen.add(nid)
        n = o['MEAN_MOTION']
        if n < 1.5:                                     # high orbits: never bright enough
            continue
        a = (MU / (n * 2 * math.pi / 86400) ** 2) ** (1 / 3)
        perigee = a * (1 - o['ECCENTRICITY']) - RE
        if perigee < 120:                               # decaying
            continue
        m, est = std_mag(o, cat, visual)
        if m + 5 * math.log10(max(perigee, 200) / 1000) - 0.75 > FAINTEST:
            continue
        sats.append([nid, o['OBJECT_NAME'], o['EPOCH'], n, o['ECCENTRICITY'], o['INCLINATION'], o['RA_OF_ASC_NODE'],
                     o['ARG_OF_PERICENTER'], o['MEAN_ANOMALY'], o['BSTAR'], o['MEAN_MOTION_DOT'], o['MEAN_MOTION_DDOT'],
                     round(m, 1), 1 if est else 0])
    # modules and visiting craft docked at a station fly the station's orbit;
    # keep the station, drop the copies that would draw on top of it
    stations = [x for x in sats if x[0] in KNOWN and x[0] != 20580]
    def docked(x):
        return x[0] not in KNOWN and any(abs(x[3] - st[3]) < 0.002 and abs(x[5] - st[5]) < 0.05 and
                                         abs((x[6] - st[6] + 180) % 360 - 180) < 0.3 and
                                         abs((x[7] + x[8] - st[7] - st[8] + 180) % 360 - 180) < 2 for st in stations)
    sats = [x for x in sats if not docked(x)]
    if len(sats) < 1000:
        raise RuntimeError(f'only {len(sats)} satellites; keeping the old file')
    data = {
        'fetched': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'fields': ['id', 'name', 'epoch', 'n', 'e', 'i', 'raan', 'argp', 'M', 'bstar', 'ndot', 'nddot', 'mag', 'est'],
        'sats': sats,
    }
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(OUT)), suffix='.tmp')
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, separators=(',', ':'))
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)
    print(f'{OUT}: {len(sats)} satellites', file=sys.stderr)


if __name__ == '__main__':
    try:
        main()
    except Exception as e:  # keep the last good file
        print(f'sky-sats: {e}', file=sys.stderr)
        sys.exit(1)
