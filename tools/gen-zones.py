#!/usr/bin/env python3
"""gen-zones.py: time zone -> (latitude, longitude, city) from the IANA zone.tab,
for when location is off: the sky from your time zone's principal city beats
the sky from someone else's town. Writes Sky/Resources/zones.json."""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = '/usr/share/zoneinfo/zone.tab'

def dms(s, deg_digits):
    sign = -1 if s[0] == '-' else 1
    s = s[1:]
    d, m, sec = int(s[:deg_digits]), int(s[deg_digits:deg_digits + 2]), int(s[deg_digits + 2:] or 0)
    return sign * (d + m / 60 + sec / 3600)

zones = {}
for line in open(SRC):
    if line.startswith('#'):
        continue
    cc, coord, tz = line.split('\t')[:3]
    m = re.match(r'([+-]\d+)([+-]\d+)', coord)
    lat, lon = m.group(1), m.group(2)
    zones[tz.strip()] = [round(dms(lat, 2), 3), round(dms(lon, 3), 3), tz.strip().split('/')[-1].replace('_', ' ')]
json.dump(zones, open(os.path.join(ROOT, 'Sky', 'Resources', 'zones.json'), 'w'), separators=(',', ':'))
print(len(zones), 'zones')
