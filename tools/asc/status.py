#!/usr/bin/env python3
"""status.py: what App Store Connect has for Sextant, and what's still empty."""
import json, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from asc import call

APP = '6828648717'
def get(p):
    d = call('GET', p)
    if 'httpError' in d:
        print('  !', p, d['httpError'], json.dumps(d['body'].get('errors', d['body']))[:300])
        return {}
    return d

def show(label, attrs, keys):
    print(f'\n== {label}')
    for k in keys:
        v = attrs.get(k)
        s = 'EMPTY' if v in (None, '', []) else (v if not isinstance(v, str) or len(v) < 90 else v[:87] + '...')
        print(f'  {k}: {s}')

app = get(f'/v1/apps/{APP}')['data']['attributes']
show('app', app, ['name', 'bundleId', 'sku', 'primaryLocale', 'contentRightsDeclaration'])

infos = get(f'/v1/apps/{APP}/appInfos?include=primaryCategory,secondaryCategory')
for info in infos.get('data', []):
    a = info['attributes']
    rel = info['relationships']
    print(f"\n== appInfo {info['id']} state={a.get('appStoreState') or a.get('state')} ageRating={a.get('appStoreAgeRating')}")
    print('  primaryCategory:', (rel['primaryCategory'].get('data') or {}).get('id', 'EMPTY'),
          ' secondaryCategory:', (rel['secondaryCategory'].get('data') or {}).get('id', 'EMPTY'))
    for loc in get(f"/v1/appInfos/{info['id']}/appInfoLocalizations").get('data', []):
        show(f"appInfo localization {loc['attributes']['locale']} ({loc['id']})", loc['attributes'],
             ['name', 'subtitle', 'privacyPolicyUrl', 'privacyChoicesUrl'])
    age = get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get('data')
    if age:
        empty = [k for k, v in age['attributes'].items() if v is None]
        print(f"\n== ageRatingDeclaration {age['id']}: {len(empty)} unanswered" + (f" ({', '.join(empty[:6])}...)" if empty else ''))

vers = get(f'/v1/apps/{APP}/appStoreVersions?filter[platform]=IOS')
for v in vers.get('data', []):
    a = v['attributes']
    print(f"\n== version {a['versionString']} ({v['id']}) state={a.get('appStoreState') or a.get('appVersionState')} "
          f"copyright={a.get('copyright') or 'EMPTY'} releaseType={a.get('releaseType')}")
    b = get(f"/v1/appStoreVersions/{v['id']}/build").get('data')
    print('  build:', b['id'] if b else 'NONE ATTACHED')
    rd = get(f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail").get('data')
    if rd:
        show('review detail', rd['attributes'], ['contactFirstName', 'contactLastName', 'contactPhone', 'contactEmail', 'demoAccountRequired', 'notes'])
    else:
        print('  review detail: NONE')
    for loc in get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations").get('data', []):
        show(f"version localization {loc['attributes']['locale']} ({loc['id']})", loc['attributes'],
             ['description', 'keywords', 'promotionalText', 'supportUrl', 'marketingUrl', 'whatsNew'])
        for ss in get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets").get('data', []):
            shots = get(f"/v1/appScreenshotSets/{ss['id']}/appScreenshots").get('data', [])
            states = [s['attributes'].get('assetDeliveryState', {}).get('state') for s in shots]
            print(f"  screenshots {ss['attributes']['screenshotDisplayType']}: {len(shots)} {states}")

price = get(f'/v1/apps/{APP}/appPriceSchedule?include=manualPrices')
print('\n== price schedule:', 'SET' if price.get('data') and price.get('included') else 'NOT SET')
avail = get(f'/v2/appAvailabilities/{APP}') or get(f'/v1/apps/{APP}/appAvailabilityV2')
print('== availability:', 'SET' if avail.get('data') else 'NOT SET (or unreadable)')
builds = get(f'/v1/builds?filter[app]={APP}&limit=5')
print('== builds uploaded:', [ (b['attributes']['version'], b['attributes']['processingState']) for b in builds.get('data', [])] or 'none')
