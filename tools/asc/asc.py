#!/usr/bin/env python3
"""asc.py: read (and lightly drive) App Store Connect through its API.

  tools/asc/.venv/bin/python tools/asc/asc.py GET /v1/apps?filter[bundleId]=dev.ducktyping.sky

Credentials: ~/.appstoreconnect/config.json {"keyId": ..., "issuerId": ...}, the key in
~/.appstoreconnect/private_keys/AuthKey_<keyId>.p8 (the same place altool looks).
Never prints the key."""
import json, os, sys, time, urllib.request, urllib.error
import jwt

HOME = os.path.expanduser('~/.appstoreconnect')

def token():
    cfg = json.load(open(os.path.join(HOME, 'config.json')))
    key = open(os.path.join(HOME, 'private_keys', f"AuthKey_{cfg['keyId']}.p8")).read()
    now = int(time.time())
    return jwt.encode({'iss': cfg['issuerId'], 'iat': now, 'exp': now + 1200, 'aud': 'appstoreconnect-v1'},
                      key, algorithm='ES256', headers={'kid': cfg['keyId'], 'typ': 'JWT'})

def call(method, path, body=None):
    req = urllib.request.Request('https://api.appstoreconnect.apple.com' + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={'Authorization': 'Bearer ' + token(), 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req) as r:
            data = r.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        return {'httpError': e.code, 'body': json.loads(e.read() or b'{}')}

if __name__ == '__main__':
    method, path = sys.argv[1], sys.argv[2]
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    print(json.dumps(call(method, path, body), indent=1))
