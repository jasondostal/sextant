# Sky — worklist

## Needs the phone
- [x] Point mode on a real device: both landscape sides verified 2026-10-28.
- [ ] Point mode in portrait (mapping added, untested).
- [ ] Point-mode guide arrow (Star Walk style, turn-direction) on the device: find the ISS with it.
- [ ] Gesture feel (inertia on drag), 60 fps check, battery.

## "What's that moving?" (how Jason actually uses it, 2026-10-29)
- [x] Opens straight into Pointing if that's how it was left.
- [x] 8 s motion trails on lit satellites, to match the dot crossing the sky.
- [x] Search opens on OVERHEAD NOW: lit satellites up right now, with heading.
- [ ] Check in the field at dawn: does the trail direction match what's seen? Offline start from cached orbits.

## Phase 1 polish (vs Star Walk 2)
- [x] Moon drawn with its phase (lit limb toward the sun), earthshine.
- [x] Named deep-sky objects (21), searchable; Milky Way texture registered (was 3.7° off).
- [ ] Ground: lighter blue-grey landscape, not near-black.
- [x] Search; tap to select. [ ] Detail card beyond the pill.
- [x] Time travel: tap the clock, pick day/hour/minute, drag the edge ruler (20 pt/unit); days are calendar days.
- [x] Visible Tonight (Jason's favourite Star Walk screen): date stepper, altitude chart on day/twilight/night bands, verdict, Show at <time> (time-travels + flies), grid; satellites get visible passes (bars + list), not orbit wiggles. Rise/set/passes gated vs Skyfield.
- [x] Visible Tonight: tap a pass row to jump to that pass. [x] Deep-sky tiles.
- [x] Detail card (tap the pill): satellites get "fades into Earth's shadow in 4:20" / "sets in 6:08" (checked vs Skyfield to 1 s) and the next day's visible passes (tap to jump); everything else gets position, magnitude, phase, distance, RA/Dec, tonight's chart and rise/highest/set with azimuths.
- [x] Night mode (eye button): Metal's last pass reads the tile back and redraws it red on a steep curve; SwiftUI layers grayscale x red. Remembered.
- [x] Constellation lines: Auto (the figure you're looking at / around the selection fades in, Star Walk's way), Always, Never; gear → Settings.
- [x] Ecliptic (amber dashes, toggle in Settings); ground fades to see a target through the Earth.
- [ ] Default FOV: Star Walk's point mode is ~88° wide, ours 75° (check if Jason had zoomed).

## Satellites
- [x] CelesTrak on device, SATCAT magnitudes bundled, SGP4 gated vs Skyfield (0.25′).
- [x] Selected satellite: track across the sky ±12 min, 30 s ticks. [ ] Next passes list.
- [ ] Pass predictions vs Heavens-Above (look-and-feel check of the magnitudes).
- [x] Labels kept out of the top readout band.
