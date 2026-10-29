# Third-party data and code

- **Astronomy Engine** (Don Cross, MIT) — `SkyCore/Sources/CAstronomy`, vendored C build.
- **HYG database v4.4** (astronexus, CC BY-SA 4.0) — `stars.bin` is derived from it
  (positions moved to epoch 2028.0 by proper motion) and is shared under the same licence.
- **d3-celestial 0.7.35** (Olaf Frohn, BSD-3-Clause) — constellation figures, names and
  the Milky Way outline in `sky-data.json`.
- **ESO/S. Brunier, "The Milky Way panorama" (eso0932a, CC BY 4.0)** — `Sky/Resources/milkyway.png`
  is derived from it (greyscale, stars median-filtered out) by `tools/gen-milkyway.py`.
- **SatelliteKit 2.1.2** (Gavin Eadie, MIT) — SGP4/SDP4, via Swift Package Manager.
- **CelesTrak** — orbital elements (GP/OMM) fetched on device; SATCAT radar cross-sections
  in `satmags.bin` (`tools/gen-satmags.py`).
