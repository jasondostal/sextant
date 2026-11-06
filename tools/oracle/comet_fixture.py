#!/usr/bin/env python3
"""comet_fixture.py — Skyfield's view of a set of comets, the correctness oracle
for SkyCore's two-body comet propagation and topocentric chain.

Skyfield's skyfield.data.mpc reads the same MPC lines (load_comets_dataframe)
and builds a two-body orbit about the Sun (comet_orbit, universal-variable
propagation), so any disagreement is ours. Comets: most from the bundled seed
(SkyCore/Sources/SkyCore/Resources/comets-seed.txt), chosen to span e < 0.9,
e within 0.01 of 1 and e > 1, plus two from the full CometEls.txt to stress the
solver (1P/Halley near aphelion, 3I/ATLAS at e = 6.1) and one synthetic exact
parabola (e = 1.000000, which Skyfield handles as its own branch).

  tools/oracle/.venv/bin/python tools/oracle/comet_fixture.py

Writes SkyCore/Tests/SkyCoreTests/Fixtures/comets.json: the MPC lines (so the
test parses exactly these), alt/az (airless apparent: light time, aberration,
no refraction), Δ, r and magnitude m = H + 5 log10 Δ + 2.5 K log10 r per case,
and rise / set / transit times for two comets in the almanac fixture's
conventions (horizon -0.5667°, maxima of altitude).
Inputs: ~/.cache/ducktyping-sky/CometEls.txt, de421.bsp.
"""
import datetime as dt, io, json, os
from skyfield.api import Loader, wgs84
from skyfield.constants import GM_SUN_Pitjeva_2005_km3_s2 as GM_SUN
from skyfield.data import mpc
from skyfield.searchlib import find_discrete, find_maxima
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CACHE = os.path.expanduser('~/.cache/ducktyping-sky')
SEED = os.path.join(ROOT, 'SkyCore', 'Sources', 'SkyCore', 'Resources', 'comets-seed.txt')
OUT = os.path.join(ROOT, 'SkyCore', 'Tests', 'SkyCoreTests', 'Fixtures', 'comets.json')

SEED_PICKS = ['2P/Encke', '22P/Kopff', '161P/Hartley-IRAS', '96P/Machholz', '342P/SOHO',
              'C/2025 Y1 (ATLAS)', 'C/2026 P3 (SWAN)', 'C/2026 C1 (Tsuchinshan)']
EXTRA_PICKS = ['1P/Halley', '3I/ATLAS']
PLACES = [('Stevens Point', 44.5236, -89.5746, 330), ('Sydney', -33.8688, 151.2093, 20)]
WHEN = ['2025-11-15T04:00:00', '2026-02-20T10:30:00', '2026-05-01T18:00:00', '2026-08-10T02:15:00',
        '2026-11-06T12:00:00', '2027-01-20T06:00:00', '2027-04-15T21:45:00', '2027-08-25T00:30:00',
        '2027-11-01T15:00:00']
ALMANAC = [('C/2026 C1 (Tsuchinshan)', ['2026-11-06', '2027-06-01']), ('2P/Encke', ['2027-01-20', '2027-02-08'])]

load = Loader(CACHE)
ts = load.timescale()
eph = load('de421.bsp')
sun, earth = eph['sun'], eph['earth']

def desig(line):
    return line[102:158].strip()

seed = {desig(l): l.rstrip('\n') for l in open(SEED) if l.strip()}
full = {desig(l): l.rstrip('\n') for l in open(os.path.join(CACHE, 'CometEls.txt')) if l.strip()}
lines = [seed[d] for d in SEED_PICKS] + [full[d] for d in EXTRA_PICKS]
base = seed['C/2026 C1 (Tsuchinshan)']
parabola = base[:41] + '1.000000' + base[49:102] + 'X/2026 P0 (synthetic parabola)'.ljust(56) + base[158:]
lines.append(parabola)

df = mpc.load_comets_dataframe(io.BytesIO(('\n'.join(lines) + '\n').encode('ascii')))
assert len(df) == len(lines)
assert df.eccentricity.iloc[-1] == 1.0
orbits = {row.designation: (mpc.comet_orbit(row, ts, GM_SUN), row) for _, row in df.iterrows()}

def iso(t):
    return t.utc_datetime().strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'

def magnitude(row, delta, r):
    # CometEls.txt carries G and the small k; the MPC's law is m = G + 5 log Δ + 2.5 k log r
    return float(row.magnitude_g + 5 * np.log10(delta) + 2.5 * row.magnitude_k * np.log10(r))

cases = []
for name, lat, lon, h in PLACES:
    obs = earth + wgs84.latlon(lat, lon, elevation_m=h)
    for when in WHEN:
        t = ts.from_datetime(dt.datetime.fromisoformat(when).replace(tzinfo=dt.timezone.utc))
        for d, (orbit, row) in orbits.items():
            astrometric = obs.at(t).observe(sun + orbit)
            alt, az, _ = astrometric.apparent().altaz()
            delta = astrometric.distance().au
            r = float(np.linalg.norm(orbit.at(ts.tt_jd(t.tt - astrometric.light_time)).position.au))
            cases.append({'place': name, 'lat': lat, 'lon': lon, 'height': h, 'utc': when + 'Z',
                          'designation': d, 'alt': alt.degrees, 'az': az.degrees,
                          'delta': float(delta), 'r': r, 'mag': magnitude(row, delta, r)})

almanac = []
for d, days in ALMANAC:
    orbit, _ = orbits[d]
    target = sun + orbit
    for name, lat, lon, h in PLACES:
        obs = earth + wgs84.latlon(lat, lon, elevation_m=h)
        for day in days:
            d0 = dt.datetime.fromisoformat(day).replace(tzinfo=dt.timezone.utc)
            t0, t1 = ts.from_datetime(d0), ts.from_datetime(d0 + dt.timedelta(days=1))
            horizon = -0.5667

            def alt(t):
                return obs.at(t).observe(target).apparent().altaz()[0].degrees
            def up(t):
                return alt(t) > horizon
            up.step_days = 1 / 48
            alt.step_days = 1 / 48
            times, ups = find_discrete(t0, t1, up)
            mt, mv = find_maxima(t0, t1, alt)
            almanac.append({'place': name, 'lat': lat, 'lon': lon, 'height': h, 'start': iso(t0), 'end': iso(t1),
                            'designation': d, 'horizon': horizon,
                            'rises': [iso(t) for t, u in zip(times, ups) if u],
                            'sets': [iso(t) for t, u in zip(times, ups) if not u],
                            'peaks': [{'t': iso(t), 'alt': float(v)} for t, v in zip(mt, mv)]})

json.dump({'meta': {'skyfield': __import__('skyfield').__version__, 'ephemeris': 'de421',
                    'gm_sun_km3_s2': GM_SUN},
           'lines': lines, 'cases': cases, 'almanac': almanac}, open(OUT, 'w'), indent=1)
print(f'{len(cases)} cases, {len(lines)} comets, {len(almanac)} comet-days -> {OUT}')
for d, (_, row) in orbits.items():
    print(f'  e={row.eccentricity:.6f} q={row.perihelion_distance_au:.4f}  {d}')
