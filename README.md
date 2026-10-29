# Sky

Jason's own star and satellite viewer: native iOS (SwiftUI + Metal), landscape,
point the phone at the sky. Personal use; replaces a paid sky-app subscription.

## Layout

- `SkyCore/` — Swift package, no UI: Astronomy Engine (vendored C), the HYG star
  catalog (`stars.bin`, epoch 2028.0), constellation figures, Milky Way. `swift test`
  runs the Stellarium oracle gate.
- `Sky/` — the app (shared by the iOS target `Sky` and the Mac target `SkyMac`).
- `tools/gen-sky.py` — rebuilds `stars.bin`/`sky-data.json` from HYG (+ optional d3-celestial).
- `tools/oracle/stellarium_fixture.py` — records Stellarium's alt/az for the gate.
- `tools/shots/shot.sh` — screenshots the Mac build at a fixed view.

## Oracles

- **Correctness: Stellarium desktop 26.3.** RemoteControl plugin on :8090, password in
  `~/.config/sky-oracle/stellarium-pass`. App Nap must be off for it
  (`defaults write org.stellarium.Stellarium NSAppSleepDisabled -bool YES`) or it never
  redraws in the background and every reading is stale. Gate: < 0.5′ for stars and bodies.
- **Look and feel: Star Walk 2** on Jason's phone. Never a numeric reference.

## Build

```
xcodegen generate
xcodebuild -project Sky.xcodeproj -scheme SkyMac -derivedDataPath DerivedData build
tools/shots/shot.sh out.png -az 200 -alt 22 -fov 95 -time 2026-10-29T02:00:00Z -lat 44.5236 -lon -89.5746
```

The iOS target signs with the free Personal Team (8N87FTKWXL) until the paid program.
Launch arguments (`-az -alt -fov -time -lat -lon -height -place`) freeze the view.
