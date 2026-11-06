# Sextant

A star and satellite viewer for iPhone: hold it up to the sky and it shows what's there,
including the satellite crossing overhead right now, with a fading trail so the dot on
screen matches the one in the sky. Native SwiftUI + Metal, no accounts, no ads, no tracking.

[**Sextant: Night Sky Objects** on the App Store](https://apps.apple.com/app/id6828648717)
· [ducktyping.dev/sextant](https://ducktyping.dev/sextant/)

## What it does

- **Point mode**: follows the phone's motion sensors; opens there by default.
- **Satellites**: CelesTrak orbits fetched on device (a snapshot ships for first launch
  offline), SGP4 via SatelliteKit, motion trails, pass tracks, "Overhead now".
- **Visible tonight**: Moon, planets, bright satellite passes and deep-sky objects
  between dusk and dawn, with an altitude chart and "Show at <time>".
- **Search** across stars, planets, constellations and satellites; time travel.

## Correctness

Positions aren't eyeballed. `SkyCore` is gated against reference software:

- stars, planets, Sun and Moon against **Stellarium 26.3**: under 0.5′;
- rise/set/transit and satellite passes against **Skyfield**.

The fixtures in `SkyCore/Tests/SkyCoreTests/Fixtures` were recorded by the scripts in
`tools/oracle/`; `swift test` in `SkyCore/` runs the gate. Recording new Stellarium
fixtures needs its RemoteControl plugin on :8090, with App Nap off
(`defaults write org.stellarium.Stellarium NSAppSleepDisabled -bool YES`) or the readings go stale.

## Layout

- `SkyCore/` — Swift package, no UI: Astronomy Engine (vendored C), the HYG star catalog
  (`stars.bin`, epoch 2028.0), constellations, Milky Way, satellites, almanac.
- `Sky/` — the app, shared by the iOS target `Sky` and the Mac target `SkyMac`
  (the Mac target exists for screenshots and quick iteration).
- `tools/` — data generators (`gen-sky.py`, `gen-satmags.py`, `gen-zones.py`, …),
  oracle fixture recorders, the Mac screenshot rig, a point-mode motion simulator,
  and App Store Connect API helpers (`tools/asc`, credentials read from `~/.appstoreconnect`).

## Build

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
xcodegen generate
cd SkyCore && swift test && cd ..
xcodebuild -project Sky.xcodeproj -scheme SkyMac -derivedDataPath DerivedData build
tools/shots/shot.sh out.png -az 200 -alt 22 -fov 95 -time 2026-10-29T02:00:00Z -lat 44.5236 -lon -89.5746
```

Launch arguments (`-az -alt -fov -time -lat -lon -height -place`) freeze the view.
To run on your own iPhone, change the team and bundle id in `project.yml`.

## Licence

MIT for the code (see `LICENSE`). Third-party code and data, and their licences, are listed
in `NOTICE.md` and in the app under Settings → Credits.
