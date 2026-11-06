# App Store listing: Sextant

Record created 2026-10-29 as **Sextant: Night Sky Objects** (the name field allows 30 characters),
bundle id `dev.ducktyping.sky`. Paste these into App Store Connect → the app → iOS App → 1.0.

## Name and subtitle (30 characters each)

- Name: `Sextant: Night Sky Objects`
- Subtitle: `Satellite tracker & star map` (28)

## Promotional text (170; can change any time without review)

See the satellite crossing overhead right now, its trail, and when it fades into Earth's shadow. Plus tonight's best passes, planets and stars.

## Description (4000)

Hold your phone up to the sky and Sextant shows what's there: stars, planets, the Moon in its phase, the Milky Way, and the satellite crossing overhead right now.

Built for the moment you see something moving up there and want to know what it is. Every lit satellite gets a short fading trail, so the dot on your screen matches the one crossing the sky. Tap it: Sextant names it, tells you how bright it is and how far away, and counts down to when it fades into Earth's shadow or sets.

SATELLITES
• Thousands of satellites from CelesTrak's orbits, refreshed twice a day
• Motion trails and a pass track with minute-by-minute times
• "Overhead now": the bright satellites lit up right now, and which way they're heading
• The next day's visible passes for any satellite, a tap away from seeing it
• Works offline from the orbits it last downloaded

TONIGHT
• Visible tonight: the Moon, planets, bright satellites, constellations and deep-sky objects worth looking at between dusk and dawn
• An altitude chart for each over day, twilight and night, with rise, set and best time
• Satellite passes you can actually see: sunlit, against a dark sky

THE SKY
• Point mode: aim your phone and the sky follows; pick anything and an arrow walks you to it
• Stars, planets, the Moon in its phase, and the Milky Way
• Constellation figures appear for the one you're looking at, or always, or never
• 21 famous clusters, nebulae and galaxies: the Pleiades, Andromeda, the Orion Nebula and more
• Time travel: drag the clock to see tonight at 3 a.m., or next week
• Night mode turns everything dim red to keep your eyes dark-adapted
• Search for any star, planet, constellation or satellite (by name or NORAD number)

ACCURATE
Star and planet positions are tested against Stellarium to under half an arcminute; satellite positions and pass times against Skyfield to under a second.

PRIVATE
No account, no ads, no tracking, no analytics. Your location is used on your phone to work out the sky and never leaves it.

## Keywords (100, comma-separated, no spaces needed; don't repeat words in the name/subtitle)

`ISS,starlink,planets,constellation,astronomy,stargazing,space station,orbit,pass,moon,telescope,sky`

## URLs

- Support: https://ducktyping.dev/sextant/
- Privacy policy: https://ducktyping.dev/sextant/privacy/
- Marketing (optional): https://ducktyping.dev/sextant/

## Category, rating, price

- Primary category: Reference; secondary: Education (Star Walk is Education, SkyGuide is Reference)
- Age rating: answer "None" throughout → 4+
- Price: Free
- Copyright: `2026 Jason Dostal`

## App Privacy (the "nutrition label")

- "Do you or your third-party partners collect data from this app?" → **No** → "Data Not Collected".
  (Location and motion are processed on device only; Apple's definition of "collect" is
  transmitting off the device, which Sextant doesn't do. CelesTrak and (1.1+) Minor Planet Center
  requests carry no user data.)

## Export compliance

`ITSAppUsesNonExemptEncryption = NO` is in the Info.plist (only HTTPS via the system), so no questions per build.

## Review notes (App Review Information → Notes)

Sextant needs no login. Location is optional: without it the sky is drawn for the principal
city of the device's time zone. Point mode (bottom-right button) uses the motion sensors; drag
to pan otherwise. Satellites are visible in the sky view only when the Sun is below the
horizon at the device's location; to see them at any time, tap the moon-and-stars button
(Visible tonight) and pick a satellite, then "Show at <time>".

1.1 addition: besides CelesTrak (satellite orbits), Sextant now downloads comet orbits from the
IAU Minor Planet Center (minorplanetcenter.net) about once a week. Neither request carries any user
data. Meteor showers are computed on device from the IMO calendar; nothing is fetched for them.

## Screenshots

6.9" display slot accepts 1290 × 2796 (iPhone 15 Pro Max, portrait) or 2796 × 1290 (landscape).
3 to 10. Suggested set: satellites with trails at dusk (night mode off); Visible tonight with
the ISS picked; the ISS card with the shadow countdown; point mode with the guide arrow;
Orion with its figure and the Moon; night mode.
