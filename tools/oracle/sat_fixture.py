#!/usr/bin/env python3
"""sat_fixture.py — Skyfield's view of a fixed set of satellites, as the
correctness oracle for SkyCore's SGP4 + TEME→topocentric chain.

Skyfield runs the reference sgp4 library (Vallado's code) from the same
CelesTrak OMM records, so any disagreement is ours. Run with the venv:

  tools/oracle/.venv/bin/python tools/oracle/sat_fixture.py

Writes SkyCore/Tests/SkyCoreTests/Fixtures/satellites.json: the OMM records
(so the test propagates exactly these) and alt/az/range/sunlit per case.
Inputs: ~/.cache/ducktyping-sky/gp-{active,visual}.json from CelesTrak.
"""
import datetime as dt, json, os
from sgp4.api import Satrec
from sgp4 import omm
from skyfield.api import EarthSatellite, Loader, wgs84

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CACHE = os.path.expanduser('~/.cache/ducktyping-sky')
OUT = os.path.join(ROOT, 'SkyCore', 'Tests', 'SkyCoreTests', 'Fixtures', 'satellites.json')

IDS = [25544, 48274, 20580, 44714, 44718, 44057, 733, 877, 2802, 5118,
       26113, 23802]          # last two: deep space (SDP4)
PLACES = [('Stevens Point', 44.5236, -89.5746, 330), ('Sydney', -33.8688, 151.2093, 20)]
OFFSETS_H = [-6, 0, 3, 9, 20, 36]   # hours from the newest epoch among the picks

load = Loader(CACHE)
ts = load.timescale()
eph = load('de421.bsp')

rows = {}
for g in ('visual', 'active'):
    for o in json.load(open(os.path.join(CACHE, f'gp-{g}.json'))):
        rows.setdefault(o['NORAD_CAT_ID'], o)
picks = [rows[i] for i in IDS]

sats = []
for o in picks:
    sr = Satrec()
    omm.initialize(sr, o)
    sats.append((o, EarthSatellite.from_satrec(sr, ts)))

newest = max(dt.datetime.fromisoformat(o['EPOCH']).replace(tzinfo=dt.timezone.utc) for o in picks)
cases = []
for name, lat, lon, h in PLACES:
    here = wgs84.latlon(lat, lon, elevation_m=h)
    for hours in OFFSETS_H:
        when = (newest + dt.timedelta(hours=hours)).replace(microsecond=0)
        t = ts.from_datetime(when)
        for o, sat in sats:
            topo = (sat - here).at(t)
            alt, az, dist = topo.altaz()
            cases.append({'place': name, 'lat': lat, 'lon': lon, 'height': h,
                          'utc': when.strftime('%Y-%m-%dT%H:%M:%SZ'), 'id': o['NORAD_CAT_ID'],
                          'alt': alt.degrees, 'az': az.degrees, 'rangeKm': dist.km,
                          'sunlit': bool(sat.at(t).is_sunlit(eph))})

with open(OUT, 'w') as f:
    json.dump({'meta': {'skyfield': __import__('skyfield').__version__, 'sgp4': __import__('sgp4').__version__},
               'elements': picks, 'cases': cases}, f, indent=1)
print(f'{len(cases)} cases, {len(picks)} satellites -> {OUT}')
