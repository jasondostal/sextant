#!/usr/bin/env python3
"""stellarium_fixture.py — record Stellarium's alt/az for a fixed set of
(place, UTC instant, object) cases, as the correctness oracle for SkyCore.

Needs Stellarium desktop running with the RemoteControl plugin on :8090; the
password lives in ~/.config/sky-oracle/stellarium-pass. Writes
SkyCore/Tests/SkyCoreTests/Fixtures/stellarium.json, which `swift test` reads,
so the tests themselves never need Stellarium.
"""
import base64, datetime as dt, json, os, time, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'SkyCore', 'Tests', 'SkyCoreTests', 'Fixtures', 'stellarium.json')
PASS = open(os.path.expanduser('~/.config/sky-oracle/stellarium-pass')).read().strip()
AUTH = 'Basic ' + base64.b64encode(f':{PASS}'.encode()).decode()

PLACES = [
    ('Stevens Point', 44.5236, -89.5746, 330),
    ('Pool 8 (Genoa)', 43.5700, -91.2300, 190),
    ('Sydney', -33.8688, 151.2093, 20),
    ('Tromsø', 69.6492, 18.9553, 10),
]
INSTANTS = ['2026-10-29T02:00:00Z', '2027-01-15T11:30:00Z', '2027-06-21T04:00:00Z', '2030-03-10T20:15:00Z']
# stars by HYG proper name; Stellarium resolves the same English names
STARS = ['Sirius', 'Vega', 'Arcturus', 'Capella', 'Rigel', 'Betelgeuse', 'Polaris', 'Altair',
         'Deneb', 'Fomalhaut', 'Antares', 'Spica', 'Canopus', 'Acrux', 'Aldebaran', 'Regulus']
BODIES = ['Sun', 'Moon', 'Mercury', 'Venus', 'Mars', 'Jupiter', 'Saturn', 'Uranus', 'Neptune']


def call(path, params=None, post=False):
    url = 'http://localhost:8090/api/' + path
    data = None
    if params and post:
        data = urllib.parse.urlencode(params).encode()
    elif params:
        url += '?' + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, data=data, headers={'Authorization': AUTH})
    with urllib.request.urlopen(req, timeout=10) as r:
        body = r.read().decode()
    return json.loads(body) if body.startswith('{') else body


def jd(iso):
    t = dt.datetime.fromisoformat(iso.replace('Z', '+00:00'))
    return t.timestamp() / 86400 + 2440587.5


def settle(lat):
    """Stellarium applies a new time/place on its next drawn frame, and it draws
    slowly in the background, so a query right after setting returns the old sky.
    Wait until Polaris sits where physics says (altitude ≈ latitude, within its
    ~0.7° from the pole) and two reads half a second apart agree."""
    last = None
    for _ in range(60):
        time.sleep(0.5)
        alt = call('objects/info', {'name': 'Polaris', 'format': 'json'})['altitude-geometric']
        if abs(alt - lat) < 1.0 and last is not None and abs(alt - last) < 1e-6:
            return
        last = alt
    raise RuntimeError(f'Stellarium never settled at latitude {lat}')


def main():
    call('main/time', {'timerate': 0}, post=True)
    cases = []
    for name, lat, lon, h in PLACES:
        call('location/setlocationfields', {'latitude': lat, 'longitude': lon, 'altitude': h}, post=True)
        for iso in INSTANTS:
            call('main/time', {'time': jd(iso), 'timerate': 0}, post=True)
            settle(lat)
            st = call('main/status')
            assert abs(st['time']['jday'] - jd(iso)) < 1e-6, st['time']
            assert abs(st['location']['latitude'] - lat) < 1e-3, st['location']
            for obj in STARS + BODIES:
                info = call('objects/info', {'name': obj, 'format': 'json'})
                cases.append({
                    'place': name, 'lat': lat, 'lon': lon, 'height': h, 'utc': iso, 'object': obj,
                    'kind': 'star' if obj in STARS else 'body',
                    'alt': info['altitude'], 'az': info['azimuth'],
                    'altGeometric': info['altitude-geometric'], 'vmag': info.get('vmag'),
                })
    st = call('main/status')
    meta = {'stellarium': '26.3', 'refraction': 'Stellarium defaults (1013.25 mbar, 15 C)',
            'generated': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
            'deltaTdays': st['time']['deltaT']}
    with open(OUT, 'w') as f:
        json.dump({'meta': meta, 'cases': cases}, f, indent=1)
    print(f'{len(cases)} cases -> {OUT}')
    call('main/time', {'time': jd(dt.datetime.now(dt.timezone.utc).isoformat()), 'timerate': 1 / 86400}, post=True)


if __name__ == '__main__':
    main()
