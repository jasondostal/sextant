import CAstronomy
import Foundation
import SatelliteKit
import simd

/// Earth satellites from CelesTrak's GP data (OMM JSON), propagated with SGP4.
public struct Satellite: Sendable {
    public let id: Int
    public let name: String
    /// Brightness at 1,000 km, half lit.
    public let standardMagnitude: Double
    /// True unless the standard magnitude is a measured value.
    public let magnitudeIsEstimate: Bool
    let propagator: any Propagable
}

public struct SatelliteCatalog: Sendable {
    public let satellites: [Satellite]
    /// Newest element-set epoch in the data.
    public let newestEpoch: Date?

    /// The faintest standard-magnitude-at-perigee kept; matches the brightness
    /// slider's far end. Drops the geostationary belt and the small stuff.
    public static let faintest = 7.5

    static let known: [Int: Double] = [
        25544: -1.8,    // ISS
        48274: -0.6,    // Tiangong (CSS)
        20580: 2.2,     // Hubble
    ]
    static let families: [(String, Double)] = [
        ("STARLINK", 6.0), ("ONEWEB", 7.5), ("KUIPER", 6.0),
    ]

    /// `groups`: one CelesTrak GP JSON array per group (e.g. visual, active).
    /// Objects appearing in more than one are kept once.
    public init(groups: [Data]) throws {
        try self.init(groups: groups, keepAll: false)
    }

    /// `keepAll` skips the brightness and orbit filters (tests use it to reach deep-space objects).
    init(groups: [Data], keepAll: Bool) throws {
        let mags = SatelliteMagnitudes.shared
        var seen = Set<Int>(), out: [Satellite] = [], newest: Date?
        let mu = 398600.4418, re = 6378.137
        for data in groups {
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for r in rows {
                guard let id = r["NORAD_CAT_ID"] as? Int, !seen.contains(id),
                      let name = r["OBJECT_NAME"] as? String,
                      let epochText = r["EPOCH"] as? String, let epoch = Self.parseEpoch(epochText),
                      let n = Self.number(r["MEAN_MOTION"]), let e = Self.number(r["ECCENTRICITY"]),
                      let i = Self.number(r["INCLINATION"]), let raan = Self.number(r["RA_OF_ASC_NODE"]),
                      let argp = Self.number(r["ARG_OF_PERICENTER"]), let m = Self.number(r["MEAN_ANOMALY"]),
                      let bstar = Self.number(r["BSTAR"])
                else { continue }
                seen.insert(id)
                guard keepAll || n >= 1.5 else { continue }         // high orbits never get bright
                let a = pow(mu / pow(n * 2 * .pi / 86400, 2), 1.0 / 3)
                let perigee = a * (1 - e) - re
                guard keepAll || perigee > 120 else { continue }    // decaying
                let (std, estimate) = Self.standardMagnitude(id: id, name: name, table: mags)
                guard keepAll || std + 5 * log10(max(perigee, 200) / 1000) - 0.75 <= Self.faintest else { continue }

                let elements = Elements(
                    commonName: name, noradIndex: UInt(id), launchName: r["OBJECT_ID"] as? String ?? "",
                    t₀: epoch, e₀: e, i₀: i, ω₀: argp, Ω₀: raan, M₀: m, n₀: n,
                    ephemType: r["EPHEMERIS_TYPE"] as? Int ?? 0, tleClass: r["CLASSIFICATION_TYPE"] as? String ?? "U",
                    tleNumber: r["ELEMENT_SET_NO"] as? Int ?? 0, revNumber: r["REV_AT_EPOCH"] as? Int ?? 0,
                    dragCoeff: bstar)
                out.append(Satellite(id: id, name: name, standardMagnitude: std, magnitudeIsEstimate: estimate,
                                     propagator: selectPropagator(elements)))
                if newest == nil || epoch > newest! { newest = epoch }
            }
        }
        satellites = Self.withoutDockedCopies(out)
        newestEpoch = newest
    }

    static func standardMagnitude(id: Int, name: String, table: SatelliteMagnitudes) -> (Double, Bool) {
        if let m = known[id] { return (m, false) }
        let upper = name.uppercased()
        for (prefix, m) in families where upper.hasPrefix(prefix) { return (m, true) }
        if let m = table[id] { return (m, true) }
        return (upper.contains("R/B") ? 4.0 : 6.5, true)
    }

    /// Modules and visiting craft docked at a station fly its orbit; keep the
    /// station and drop the copies that would draw on top of it.
    static func withoutDockedCopies(_ sats: [Satellite]) -> [Satellite] {
        let stations = sats.filter { $0.id == 25544 || $0.id == 48274 }.map(\.propagator.tle)
        guard !stations.isEmpty else { return sats }
        func angle(_ a: Double, _ b: Double) -> Double { abs(remainder(a - b, 2 * .pi)) }
        return sats.filter { s in
            if known[s.id] != nil { return true }
            let t = s.propagator.tle
            return !stations.contains { st in
                abs(t.n₀ - st.n₀) / st.n₀ < 2e-4 && abs(t.i₀ - st.i₀) < 0.001 &&
                    angle(t.Ω₀, st.Ω₀) < 0.005 && angle(t.ω₀ + t.M₀, st.ω₀ + st.M₀) < 0.035
            }
        }
    }

    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// CelesTrak epochs are UTC without a zone, usually with microseconds.
    /// Parsed by hand: a formatter per record costs more than the rest of the load.
    static func parseEpoch(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 19 else { return nil }
        func int(_ a: Int, _ b: Int) -> Int? {
            var v = 0
            for c in u[a..<b] { guard c >= 48, c <= 57 else { return nil }; v = v * 10 + Int(c - 48) }
            return v
        }
        guard let y = int(0, 4), let mo = int(5, 7), let d = int(8, 10),
              let h = int(11, 13), let mi = int(14, 16), let sec = int(17, 19) else { return nil }
        // days from the civil date (Howard Hinnant's algorithm)
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
        var t = Double(days * 86400 + h * 3600 + mi * 60 + sec)
        if u.count > 20, u[19] == 46, let frac = Double("0" + s.dropFirst(19)) { t += frac }
        return Date(timeIntervalSince1970: t)
    }
}

/// Standard magnitudes by NORAD id, from tools/gen-satmags.py (SATCAT radar
/// cross-sections, or the object's type).
public struct SatelliteMagnitudes: Sendable {
    private let ids: [UInt32]
    private let mags: [Int16]

    public static let shared: SatelliteMagnitudes = {
        let url = Bundle.module.url(forResource: "Resources", withExtension: nil)!.appendingPathComponent("satmags.bin")
        return SatelliteMagnitudes(packed: (try? Data(contentsOf: url)) ?? Data())
    }()

    init(packed data: Data) {
        var ids: [UInt32] = [], mags: [Int16] = []
        data.withUnsafeBytes { raw in
            for o in stride(from: 0, to: raw.count - 5, by: 6) {
                ids.append(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian)
                mags.append(raw.loadUnaligned(fromByteOffset: o + 4, as: Int16.self).littleEndian)
            }
        }
        self.ids = ids
        self.mags = mags
    }

    subscript(id: Int) -> Double? {
        var lo = 0, hi = ids.count
        let key = UInt32(id)
        while lo < hi {
            let mid = (lo + hi) / 2
            if ids[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        return lo < ids.count && ids[lo] == key ? Double(mags[lo]) / 100 : nil
    }
}

/// Where a satellite is, for one observer at one instant.
public struct SatellitePosition: Sendable {
    /// Airless direction (satellites are close; refraction is applied when drawn).
    public let horizontal: Horizontal
    public let rangeKm: Double
    /// In sunlight (outside Earth's shadow).
    public let sunlit: Bool
    /// Apparent magnitude if sunlit.
    public let magnitude: Double
}

/// The Earth-fixed geometry for satellites at one instant: Greenwich sidereal
/// angle, the observer's position and local axes, the Sun's direction.
/// Satellites live in SGP4's TEME frame; this rotates them onto the ground.
public struct SatelliteFrame: Sendable {
    public let date: Date
    let gmst: Double
    let observer: SIMD3<Double>               // km, Earth-fixed
    let north, west, up: SIMD3<Double>
    let sun: SIMD3<Double>                    // unit, Earth-fixed

    static let earthRadius = 6378.137

    public init(date: Date, observer o: Observer) {
        self.date = date
        // GMST (IAU 1982), the angle SGP4's TEME frame is defined against; UT1 ≈ UTC
        let t = (date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0) / 36525
        var s = 67310.54841 + (876600 * 3600 + 8640184.812866) * t + 0.093104 * t * t - 6.2e-6 * t * t * t
        s = s.truncatingRemainder(dividingBy: 86400)
        gmst = s / 240 * .pi / 180

        let lat = o.latitude * .pi / 180, lon = o.longitude * .pi / 180
        let f = 1 / 298.257223563, e2 = f * (2 - f)
        let n = Self.earthRadius / sqrt(1 - e2 * sin(lat) * sin(lat))
        let h = o.height / 1000
        observer = SIMD3((n + h) * cos(lat) * cos(lon), (n + h) * cos(lat) * sin(lon), (n * (1 - e2) + h) * sin(lat))
        up = SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        north = SIMD3(-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat))
        west = SIMD3(sin(lon), -cos(lon), 0)

        // the Sun, true equator of date ≈ TEME to well under a degree, which is plenty for shadows
        var at = astroTime(date)
        let v = Astronomy_GeoVector(BODY_SUN, at, ABERRATION)
        let eqd = Astronomy_RotateVector(Astronomy_Rotation_EQJ_EQD(&at), v)
        sun = Self.rotate(simd_normalize(SIMD3(eqd.x, eqd.y, eqd.z)), by: gmst)
    }

    static func rotate(_ v: SIMD3<Double>, by theta: Double) -> SIMD3<Double> {
        SIMD3(cos(theta) * v.x + sin(theta) * v.y, -sin(theta) * v.x + cos(theta) * v.y, v.z)
    }

    public func position(of sat: Satellite) -> SatellitePosition? {
        guard let pv = try? sat.propagator.getPVCoordinates(date) else { return nil }
        let teme = SIMD3(pv.position.x, pv.position.y, pv.position.z) / 1000
        let r = Self.rotate(teme, by: gmst)
        let rho = r - observer
        let range = simd_length(rho)
        let local = SIMD3(simd_dot(rho, north), simd_dot(rho, west), simd_dot(rho, up))

        // cylindrical shadow: behind the Earth and within one Earth radius of the Sun line
        let along = simd_dot(r, sun)
        let sunlit = along > 0 || simd_length(r - along * sun) > Self.earthRadius
        // diffuse sphere, phase angle between the Sun and us as seen from the satellite
        let cosPhase = simd_dot(sun, -rho / range)
        let phase = acos(max(-1, min(1, cosPhase)))
        let light = max((.pi - phase) * cosPhase + sin(phase), 1e-4)
        let mag = sat.standardMagnitude + 5 * log10(range / 1000) - 2.5 * log10(light)
        return SatellitePosition(horizontal: Horizontal(vector: local), rangeKm: range, sunlit: sunlit, magnitude: mag)
    }
}
