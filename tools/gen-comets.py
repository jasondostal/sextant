#!/usr/bin/env python3
"""gen-comets.py — the bundled comet seed: the MPC's comet elements cut down to
the ones that could plausibly be seen.

Reads CometEls.txt (https://minorplanetcenter.net/iau/MPCORB/CometEls.txt,
cached at ~/.cache/ducktyping-sky/CometEls.txt), propagates every comet with
Skyfield (two-body, the same model SkyCore uses) every 5 days from 60 days ago
to two years ahead, and keeps those whose predicted total magnitude
m = H + 5 log10(Δ) + 2.5 K log10(r) gets brighter than LIMIT at some point.
Generous on purpose: the app filters again at runtime (CometCatalog.bright).

Writes the kept lines VERBATIM (MPC one-line format) to
SkyCore/Sources/SkyCore/Resources/comets-seed.txt, so the bundled seed and a
fresh download from the MPC go through the same parser.

  tools/oracle/.venv/bin/python tools/gen-comets.py [--limit 14] [--from 2026-11-06]
"""
import argparse, datetime as dt, io, os
import numpy as np
from skyfield.api import Loader
from skyfield.constants import GM_SUN_Pitjeva_2005_km3_s2 as GM_SUN
from skyfield.data import mpc

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.expanduser('~/.cache/ducktyping-sky')
OUT = os.path.join(ROOT, 'SkyCore', 'Sources', 'SkyCore', 'Resources', 'comets-seed.txt')

ap = argparse.ArgumentParser()
ap.add_argument('--limit', type=float, default=14.0)
ap.add_argument('--from', dest='start', default=dt.date.today().isoformat())
ap.add_argument('--input', default=os.path.join(CACHE, 'CometEls.txt'))
args = ap.parse_args()

load = Loader(CACHE)
ts = load.timescale()
eph = load('de421.bsp')
sun, earth = eph['sun'], eph['earth']

raw = open(args.input, 'rb').read()
lines = [l for l in raw.decode('ascii').splitlines() if l.strip()]
df = mpc.load_comets_dataframe(io.BytesIO(raw))
assert len(df) == len(lines), (len(df), len(lines))

start = dt.datetime.fromisoformat(args.start).replace(tzinfo=dt.timezone.utc) - dt.timedelta(days=60)
t = ts.from_datetimes([start + dt.timedelta(days=5 * k) for k in range(int((730 + 60) / 5) + 1)])
e_bary = earth.at(t).position.au
s_bary = sun.at(t).position.au

kept = []
for (_, row), line in zip(df.iterrows(), lines):
    if np.isnan(row.magnitude_g) or np.isnan(row.magnitude_k):
        continue
    orbit = mpc.comet_orbit(row, ts, GM_SUN)
    helio = orbit.at(t).position.au                    # geometric is plenty for a cut
    r = np.linalg.norm(helio, axis=0)
    delta = np.linalg.norm(helio + s_bary - e_bary, axis=0)
    m = row.magnitude_g + 5 * np.log10(delta) + 2.5 * row.magnitude_k * np.log10(r)
    if np.nanmin(m) < args.limit:
        kept.append((float(np.nanmin(m)), line))

with open(OUT, 'w') as f:
    for _, line in kept:
        f.write(line.rstrip() + '\n')
print(f'{len(kept)} of {len(lines)} comets brighter than {args.limit} between '
      f'{start.date()} and {(start + dt.timedelta(days=790)).date()} -> {OUT}')
for m, line in sorted(kept)[:15]:
    print(f'  {m:5.1f}  {line[102:158].strip()}')
