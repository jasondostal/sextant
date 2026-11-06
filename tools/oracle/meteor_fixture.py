#!/usr/bin/env python3
"""meteor_fixture.py — the oracle for SkyCore's meteor showers.

Source: IMO 2026 Meteor Shower Calendar (Rendtel, ed.; IMO INFO(3-25),
https://www.imo.net/files/meteor-shower/cal2026.pdf), Table 5 (Working List of
Visual Meteor Showers: activity dates, peak solar longitude λ☉ J2000, radiant,
V∞, r, ZHR) and Table 6 (radiant positions every 5 days). The Antihelion Source
is left out (no single radiant).

Skyfield + DE421 turn each peak λ☉ into the 2026 instant (geocentric Sun,
geometric, ecliptic and equinox J2000, which is what IMO's "λ⊙ for the equinox
2000.0" means), and the activity dates into λ☉. The printed peak dates are
kept so the test can check that the instant falls on IMO's day. Table 6 nodes
inside each activity window (for the short Aurigids and Phoenicids, the ones
either side of it) are kept for the radiant-drift check; the script also prints
the daily drift, the least-squares line through them pinned to the Table 5 peak
radiant, which is what the Swift table (SkyCore/Sources/SkyCore/MeteorShowers.swift)
carries.

  tools/oracle/.venv/bin/python tools/oracle/meteor_fixture.py

Writes SkyCore/Tests/SkyCoreTests/Fixtures/meteors.json.
"""
import datetime as dt, json, os
import numpy as np
from skyfield.api import Loader
from skyfield.framelib import ecliptic_J2000_frame

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CACHE = os.path.expanduser('~/.cache/ducktyping-sky')
OUT = os.path.join(ROOT, 'SkyCore', 'Tests', 'SkyCoreTests', 'Fixtures', 'meteors.json')

M = {m: i + 1 for i, m in enumerate('Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.split())}

# code: (activity start, end, IMO peak date, λ☉ peak, Table 6 nodes "Mon D ra dec; ...")
TABLE = {
    'QUA': ('Dec 28', 'Jan 12', 'Jan 03', 283.15, 'Dec 30 226 50; Jan 0 228 50; Jan 5 231 49; Jan 10 234 48'),
    'GUM': ('Jan 10', 'Jan 22', 'Jan 18', 298.0, 'Jan 10 220 71; Jan 15 224 69; Jan 20 228 67; Jan 25 232 65'),
    'ACE': ('Jan 31', 'Feb 20', 'Feb 08', 319.4, 'Jan 30 199 -56; Feb 5 206 -58; Feb 10 213 -59; Feb 15 219 -61; Feb 20 224 -62'),
    'LYR': ('Apr 14', 'Apr 30', 'Apr 22', 32.32, 'Apr 15 263 34; Apr 20 269 34; Apr 25 274 34; Apr 30 279 34'),
    'PPU': ('Apr 15', 'Apr 28', 'Apr 24', 33.5, 'Apr 15 106 -44; Apr 20 109 -45; Apr 25 111 -45'),
    'ETA': ('Apr 19', 'May 28', 'May 06', 45.5, 'Apr 20 323 -7; Apr 25 328 -5; Apr 30 332 -3; May 5 337 -1; '
                                                'May 10 341 1; May 15 345 3; May 20 349 5; May 25 353 7'),
    'ELY': ('May 03', 'May 14', 'May 11', 50.0, 'May 5 286 43; May 10 291 43; May 15 296 44'),
    'ARI': ('May 14', 'Jun 24', 'Jun 07', 76.7, 'Jun 5 42 24; Jun 10 47 24'),
    'JBO': ('Jun 22', 'Jul 02', 'Jun 22', 90.3, 'Jun 25 221 48; Jun 30 222 47'),
    'JPE': ('Jul 01', 'Jul 20', 'Jul 10', 108.0, 'Jul 5 343 10; Jul 10 347 11; Jul 15 351 12; Jul 20 356 13'),
    'GDR': ('Jul 25', 'Jul 31', 'Jul 28', 125.13, 'Jul 25 277 51; Jul 30 282 51'),
    'SDA': ('Jul 12', 'Aug 23', 'Jul 31', 128.0, 'Jul 15 329 -19; Jul 20 333 -18; Jul 25 337 -17; Jul 30 340 -16; '
                                                 'Aug 5 345 -14; Aug 10 349 -13; Aug 15 352 -12; Aug 20 356 -11'),
    'CAP': ('Jul 03', 'Aug 15', 'Jul 31', 128.0, 'Jul 5 285 -16; Jul 10 289 -15; Jul 15 294 -14; Jul 20 299 -12; '
                                                 'Jul 25 303 -11; Jul 30 307 -10; Aug 5 313 -8; Aug 10 318 -6'),
    'ERI': ('Jul 31', 'Aug 19', 'Aug 07', 135.0, 'Aug 5 39 -14; Aug 10 44 -12; Aug 15 48 -10'),
    'PER': ('Jul 17', 'Aug 24', 'Aug 13', 140.0, 'Jul 20 11 52; Jul 25 22 53; Jul 30 29 54; Aug 5 37 56; '
                                                 'Aug 10 45 57; Aug 15 51 58; Aug 20 57 58'),
    'KCG': ('Aug 03', 'Aug 28', 'Aug 17', 144.0, 'Aug 5 281 45; Aug 10 284 49; Aug 15 287 53; Aug 20 289 56; Aug 25 291 59'),
    'AUR': ('Aug 28', 'Sep 05', 'Sep 01', 158.6, 'Aug 25 85 40; Aug 30 90 39; Sep 5 96 39; Sep 10 102 39'),
    'SPE': ('Sep 05', 'Sep 21', 'Sep 09', 166.7, 'Sep 5 43 40; Sep 10 48 40; Sep 15 53 40; Sep 20 59 41'),
    'SLY': ('Sep 10', 'Oct 08', 'Sep 13', 170.0, 'Sep 20 120 48; Sep 25 127 47; Sep 30 133 46; Oct 5 140 45'),
    'DSX': ('Sep 20', 'Oct 06', 'Oct 01', 188.0, 'Sep 25 152 -2; Sep 30 156 -2; Oct 5 160 -2'),
    'OCT': ('Oct 05', 'Oct 06', 'Oct 06', 192.58, 'Oct 5 164 79'),
    'DRA': ('Oct 06', 'Oct 10', 'Oct 09', 195.4, 'Oct 10 262 54'),
    'EGE': ('Oct 14', 'Oct 27', 'Oct 18', 205.0, 'Oct 15 99 27; Oct 20 104 27; Oct 25 109 27'),
    'ORI': ('Oct 02', 'Nov 07', 'Oct 21', 208.0, 'Oct 5 85 14; Oct 10 88 15; Oct 15 91 15; Oct 20 94 16; '
                                                 'Oct 25 98 16; Oct 30 101 16; Nov 5 105 17'),
    'LMI': ('Oct 19', 'Oct 27', 'Oct 24', 211.0, 'Oct 20 158 39; Oct 25 163 37'),
    'STA': ('Sep 20', 'Nov 20', 'Nov 05', 223.0, 'Sep 20 18 5; Sep 25 21 6; Sep 30 25 7; Oct 5 28 8; Oct 10 32 9; '
                                                 'Oct 15 36 11; Oct 20 40 12; Oct 25 43 13; Oct 30 47 14; Nov 5 52 15; '
                                                 'Nov 10 56 15; Nov 15 60 16; Nov 20 64 16'),
    'NTA': ('Oct 20', 'Dec 10', 'Nov 12', 230.0, 'Oct 20 38 18; Oct 25 43 19; Oct 30 47 20; Nov 5 52 21; Nov 10 56 22; '
                                                 'Nov 15 61 23; Nov 20 65 24; Nov 25 70 24; Nov 30 74 24'),
    'LEO': ('Nov 06', 'Nov 30', 'Nov 17', 235.27, 'Nov 10 147 24; Nov 15 150 23; Nov 20 153 21; Nov 25 156 20; Nov 30 159 19'),
    'AMO': ('Nov 15', 'Nov 25', 'Nov 22', 239.32, 'Nov 15 112 2; Nov 20 116 1; Nov 25 120 0'),
    'NOO': ('Nov 13', 'Dec 06', 'Nov 28', 246.0, 'Nov 15 81 16; Nov 20 84 16; Nov 25 88 16; Nov 30 92 16'),
    'PHO': ('Dec 01', 'Dec 05', 'Dec 02', 249.5, 'Nov 30 7 -27; Dec 5 10 -27; Dec 10 13 -28'),
    'PUP': ('Dec 01', 'Dec 15', 'Dec 07', 255.0, 'Dec 5 122 -45; Dec 10 125 -45; Dec 15 128 -45'),
    'MON': ('Dec 01', 'Dec 19', 'Dec 09', 257.0, 'Dec 5 98 9; Dec 10 101 8; Dec 15 105 7'),
    'HYD': ('Dec 03', 'Dec 20', 'Dec 09', 257.0, 'Dec 5 122 3; Dec 10 126 2; Dec 15 130 1; Dec 20 134 0'),
    'GEM': ('Dec 04', 'Dec 20', 'Dec 14', 262.2, 'Dec 5 103 33; Dec 10 108 33; Dec 15 113 33; Dec 20 118 32'),
    'COM': ('Dec 04', 'Jan 30', 'Dec 23', 271.0, 'Dec 5 148 35; Dec 10 152 34; Dec 15 157 32; Dec 20 161 30; '
                                                 'Dec 25 166 28; Dec 30 170 26; Jan 0 172 25; Jan 5 176 24; '
                                                 'Jan 10 180 23; Jan 15 185 21; Jan 20 189 19; Jan 25 194 17; Jan 30 198 16'),
    'URS': ('Dec 17', 'Dec 26', 'Dec 22', 270.7, 'Dec 20 217 76; Dec 25 217 74'),
}
# Table 5 radiant at maximum, α δ in degrees
RADIANT = {
    'QUA': (230, 49), 'GUM': (228, 67), 'ACE': (211, -58), 'LYR': (271, 34), 'PPU': (110, -45),
    'ETA': (338, -1), 'ELY': (291, 43), 'ARI': (43, 24), 'JBO': (221, 48), 'JPE': (347, 11),
    'GDR': (280, 51), 'SDA': (340, -16), 'CAP': (307, -10), 'ERI': (41, -11), 'PER': (48, 58),
    'KCG': (286, 59), 'AUR': (91, 39), 'SPE': (48, 40), 'SLY': (113, 56), 'DSX': (156, -2),
    'OCT': (164, 79), 'DRA': (262, 54), 'EGE': (102, 27), 'ORI': (95, 16), 'LMI': (162, 37),
    'STA': (52, 15), 'NTA': (58, 22), 'LEO': (152, 22), 'AMO': (117, 1), 'NOO': (91, 16),
    'PHO': (8, -27), 'PUP': (123, -45), 'MON': (100, 8), 'HYD': (125, 2), 'GEM': (112, 33),
    'COM': (164, 29), 'URS': (217, 76),
}
YEAR = 2026

load = Loader(CACHE)
ts = load.timescale()
eph = load('de421.bsp')
sun, earth = eph['sun'], eph['earth']

def solar_longitude(t):
    _, lon, _ = earth.at(t).observe(sun).frame_latlon(ecliptic_J2000_frame)
    return lon.degrees

def utc(d):
    return ts.from_datetime(d.replace(tzinfo=dt.timezone.utc))

def near(text, anchor):
    """'Mon D' (D may be 0, the last of the month before) in whichever year puts it nearest `anchor`."""
    mon, day = text.split()
    best = None
    for y in (anchor.year - 1, anchor.year, anchor.year + 1):
        d = dt.datetime(y, M[mon], 1) + dt.timedelta(days=int(day) - 1)
        if best is None or abs(d - anchor) < abs(best - anchor):
            best = d
    return best

def wrap180(x):
    return (x + 180) % 360 - 180

def iso(t):
    return t.utc_datetime().strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'

showers = []
for code, (start, end, date, lam, nodes) in TABLE.items():
    printed = near(date, dt.datetime(YEAR, 7, 1))
    # Newton on λ☉(t) = λ, from noon of the printed day
    jd = utc(printed + dt.timedelta(hours=12)).tt
    for _ in range(8):
        jd += wrap180(lam - solar_longitude(ts.tt_jd(jd))) / 0.985647
    peak = ts.tt_jd(jd)
    pdt = peak.utc_datetime().replace(tzinfo=None)
    t_start = utc(near(start, pdt))
    t_end = utc(near(end, pdt) + dt.timedelta(days=1))
    rows = []
    for n in nodes.split(';'):
        mon, day, ra, dec = n.split()
        when = near(f'{mon} {day}', pdt)
        rows.append({'utc': iso(utc(when)), 'ra': float(ra), 'dec': float(dec),
                     'days': (when - pdt).total_seconds() / 86400})
    # least squares through the nodes, pinned to the peak radiant: slope = Σ d·Δ / Σ d²
    ra0, dec0 = RADIANT[code]
    days = np.array([r['days'] for r in rows])
    dras = np.array([wrap180(r['ra'] - ra0) for r in rows])
    ddecs = np.array([r['dec'] - dec0 for r in rows])
    dra, ddec = (days @ dras) / (days @ days), (days @ ddecs) / (days @ days)
    # ...unless Table 6's own line misses Table 5's peak radiant by more than 4° (the
    # κ-Cygnids and September Lyncids): then the tables disagree, pinning would bend the
    # rate, and the free line's slope is the drift
    # Otherwise, of the pinned and the free slope, keep whichever (starting from the peak
    # radiant) comes closest to the worst node: drifts that curve, like the α-Capricornids',
    # are better served by the free one.
    disagree = False
    if len(rows) > 1:
        (fra, fra0), (fdec, fdec0) = np.polyfit(days, dras, 1), np.polyfit(days, ddecs, 1)
        off = np.hypot(fra0 * np.cos(np.radians(dec0)), fdec0)
        if off > 4:      # (the curving α-Capricornid drift misses by 2.2°: that's not a disagreement)
            print(f'  {code}: Table 6 line misses the peak radiant by {off:.1f}°; free slope')
            dra, ddec, disagree = fra, fdec, True
        else:
            def worst(sra, sdec):
                cosd = np.cos(np.radians([r['dec'] for r in rows]))
                return np.max(np.hypot((dras - sra * days) * cosd, ddecs - sdec * days))
            if worst(fra, fdec) < worst(dra, ddec):
                dra, ddec = fra, fdec
    showers.append({'code': code, 'peakLongitude': lam, 'ra': ra0, 'dec': dec0, 'tablesDisagree': disagree,
                    'imoPeakDate': printed.strftime('%Y-%m-%d'),
                    'peak': iso(peak), 'startLongitude': float(solar_longitude(t_start)),
                    'endLongitude': float(solar_longitude(t_end)),
                    'start': iso(t_start), 'end': iso(t_end), 'nodes': rows,
                    'driftRA': float(dra), 'driftDec': float(ddec)})
    print(f'{code}  peak {iso(peak)} (IMO {printed:%b %d})  λ {solar_longitude(t_start):6.1f} .. '
          f'{solar_longitude(t_end):6.1f}  drift {dra:+.2f} {ddec:+.2f} °/day')

json.dump({'meta': {'source': 'IMO 2026 Meteor Shower Calendar, Tables 5 and 6',
                    'skyfield': __import__('skyfield').__version__, 'ephemeris': 'de421'},
           'year': YEAR, 'showers': showers}, open(OUT, 'w'), indent=1)
print(len(showers), 'showers ->', OUT)
