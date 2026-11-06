import CAstronomy
import Foundation
import simd

/// Heliocentric osculating elements of a comet, as the Minor Planet Center
/// publishes them: J2000 ecliptic and equinox, perihelion time in TT.
public struct CometElements: Equatable, Sendable {
    /// Perihelion passage, TT days since J2000.0 (2000-01-01T12:00 TT).
    public let perihelionTT: Double
    /// q, AU.
    public let perihelionDistance: Double
    public let eccentricity: Double
    /// ω, Ω, i in degrees (J2000 ecliptic).
    public let argumentOfPerihelion: Double
    public let longitudeOfNode: Double
    public let inclination: Double
    /// Epoch of osculation, TT days since J2000.0. Two-body propagation drifts
    /// from the real comet the further you get from it (planetary perturbations).
    public let epochTT: Double
    /// Total-magnitude law m = H + 5 log10 Δ + 2.5 K log10 r (the MPC's M1 and K1;
    /// see `Comet.magnitude(delta:r:)`).
    public let absoluteMagnitude: Double
    public let slope: Double

    /// Perifocal axes in J2000 equatorial: P toward perihelion, Q 90° ahead in the orbit.
    let p: SIMD3<Double>, q: SIMD3<Double>

    public init(perihelionTT: Double, perihelionDistance: Double, eccentricity: Double,
                argumentOfPerihelion: Double, longitudeOfNode: Double, inclination: Double,
                epochTT: Double, absoluteMagnitude: Double, slope: Double) {
        self.perihelionTT = perihelionTT
        self.perihelionDistance = perihelionDistance
        self.eccentricity = eccentricity
        self.argumentOfPerihelion = argumentOfPerihelion
        self.longitudeOfNode = longitudeOfNode
        self.inclination = inclination
        self.epochTT = epochTT
        self.absoluteMagnitude = absoluteMagnitude
        self.slope = slope
        let w = argumentOfPerihelion * .pi / 180, n = longitudeOfNode * .pi / 180, i = inclination * .pi / 180
        let pe = SIMD3(cos(w) * cos(n) - sin(w) * sin(n) * cos(i),
                       cos(w) * sin(n) + sin(w) * cos(n) * cos(i),
                       sin(w) * sin(i))
        let qe = SIMD3(-sin(w) * cos(n) - cos(w) * sin(n) * cos(i),
                       -sin(w) * sin(n) + cos(w) * cos(n) * cos(i),
                       cos(w) * sin(i))
        p = eclipticToEquatorial(pe)
        q = eclipticToEquatorial(qe)
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.perihelionTT == b.perihelionTT && a.perihelionDistance == b.perihelionDistance &&
            a.eccentricity == b.eccentricity && a.argumentOfPerihelion == b.argumentOfPerihelion &&
            a.longitudeOfNode == b.longitudeOfNode && a.inclination == b.inclination &&
            a.epochTT == b.epochTT && a.absoluteMagnitude == b.absoluteMagnitude && a.slope == b.slope
    }

    /// Heliocentric position, AU, J2000 equatorial, at a TT instant (days since J2000.0).
    /// Two-body motion about the Sun, one code path for every eccentricity.
    public func heliocentric(tt: Double) -> SIMD3<Double> {
        let (x, y) = Kepler.perifocal(q: perihelionDistance, e: eccentricity, dt: tt - perihelionTT)
        return x * p + y * q
    }
}

/// Two-body propagation from perihelion in universal variables (Battin; Curtis,
/// *Orbital Mechanics for Engineering Students*, §3.7). The universal anomaly χ
/// covers ellipse, parabola and hyperbola alike, and the Stumpff functions go
/// smoothly through z = αχ² = 0, so e within 1e-6 of 1 is no special case.
enum Kepler {
    /// GM of the Sun in AU³/day²: Pitjeva (2015)'s 132712440042 km³/s², the value
    /// Skyfield's comet examples (and our oracle) use.
    static let mu = 0.00029591220828572624

    /// Stumpff functions C(z) = (1 − cos √z)/z and S(z) = (√z − sin √z)/z^{3/2},
    /// continued through z ≤ 0 with cosh/sinh, series near 0.
    static func stumpff(_ z: Double) -> (c: Double, s: Double) {
        if abs(z) < 0.1 {
            // C = Σ (−z)^n/(2n+2)!, S = Σ (−z)^n/(2n+3)!: 10 terms reach 1e-26 at |z| = 0.1
            var c = 0.0, s = 0.0, cn = 0.5, sn = 1.0 / 6
            for n in 0..<10 {
                c += cn
                s += sn
                let m = Double(2 * n)
                cn *= -z / ((m + 3) * (m + 4))
                sn *= -z / ((m + 4) * (m + 5))
            }
            return (c, s)
        } else if z > 0 {
            let r = z.squareRoot()
            return ((1 - cos(r)) / z, (r - sin(r)) / (z * r))
        } else {
            let r = (-z).squareRoot()
            return ((cosh(r) - 1) / -z, (sinh(r) - r) / (-z * r))
        }
    }

    /// In-plane position (x toward perihelion, y along the perihelion velocity), AU,
    /// `dt` days after perihelion passage.
    ///
    /// Kepler's equation from perihelion (r₀ = q, radial velocity 0), with α = 1/a = (1 − e)/q:
    ///     √μ·dt = q·χ + e·χ³·S(αχ²),   r = dF/dχ = q + e·χ²·C(αχ²)
    /// F is odd and strictly increasing in χ, so solve for |dt| on a bracket and
    /// polish with Newton (falling back to bisection whenever a step leaves the
    /// bracket or overflows). The bracket comes from the parabola: S ≥ 1/6 on a
    /// hyperbola and ≤ 1/6 on an ellipse, so the parabolic χ bounds the root from
    /// above (e ≥ 1) or below (e < 1); an ellipse's time is first reduced to the
    /// nearest perihelion, which caps χ at π/√α (half an orbit).
    static func perifocal(q: Double, e: Double, dt rawDt: Double) -> (Double, Double) {
        let alpha = (1 - e) / q
        let rootMu = mu.squareRoot()
        var dt = rawDt
        if alpha > 0 {
            let period = 2 * .pi / (mu * alpha * alpha * alpha).squareRoot()
            dt -= period * (dt / period).rounded()
        }
        let sign: Double = dt < 0 ? -1 : 1
        let target = rootMu * abs(dt)

        // parabola: χ³/6 + qχ = target, solved in the stable sinh form of Cardano
        let k = (2 * q).squareRoot()
        let chiP = 2 * k * sinh(asinh(3 * target / (2 * q * k)) / 3)
        var lo: Double, hi: Double
        if alpha > 0 {
            hi = .pi / alpha.squareRoot()
            lo = min(chiP, hi)
        } else {
            lo = 0
            hi = chiP
        }

        func f(_ chi: Double) -> (value: Double, slope: Double) {
            let (c, s) = stumpff(alpha * chi * chi)
            return (q * chi + e * chi * chi * chi * s - target, q + e * chi * chi * c)
        }

        var chi = alpha > 0 ? min(max(chiP, lo), hi) : chiP
        for _ in 0..<100 {
            let (v, slope) = f(chi)
            if !v.isFinite || v > 0 { hi = chi } else { lo = chi }
            if v == 0 { break }
            var next = chi - v / slope
            if !next.isFinite || next <= lo || next >= hi { next = (lo + hi) / 2 }
            if abs(next - chi) <= 1e-15 * max(1, abs(chi)) || hi - lo <= 1e-15 * max(1, abs(chi)) {
                chi = next
                break
            }
            chi = next
        }

        // Lagrange coefficients from perihelion: x = f·q, y = g·v_q, with
        // f = 1 − χ²C/q and g = |dt| − χ³S/√μ = qχ(1 − zS)/√μ (the form without cancellation)
        let z = alpha * chi * chi
        let (c, s) = stumpff(z)
        let g = q * chi * (1 - z * s) / rootMu
        let vPeri = (mu * (1 + e) / q).squareRoot()
        return (q - chi * chi * c, sign * g * vPeri)
    }
}

/// J2000 ecliptic → J2000 equatorial, with the obliquity of SPICE's ECLIPJ2000
/// frame (84381.448″), which is the frame the MPC's elements are referred to.
func eclipticToEquatorial(_ v: SIMD3<Double>) -> SIMD3<Double> {
    let c = 0.91748206206918181, s = 0.39777715593191371
    return SIMD3(v.x, c * v.y - s * v.z, s * v.y + c * v.z)
}

/// The inverse: J2000 equatorial → J2000 ecliptic.
func equatorialToEcliptic(_ v: SIMD3<Double>) -> SIMD3<Double> {
    let c = 0.91748206206918181, s = 0.39777715593191371
    return SIMD3(v.x, c * v.y + s * v.z, -s * v.y + c * v.z)
}

/// A comet, from one line of the MPC's `CometEls.txt`.
public struct Comet: Identifiable, Equatable, Sendable {
    /// The designation alone: "C/2026 C1", "2P", "73P-BT", "A/2018 W3".
    public let id: String
    /// The name, if it has one: "Tsuchinshan", "Encke".
    public let name: String?
    /// As the MPC writes it: "C/2026 C1 (Tsuchinshan)", "2P/Encke".
    public let displayName: String
    public let elements: CometElements
    /// The MPC line it came from, verbatim, for caching a refreshed catalog.
    public let line: String

    /// Total visual magnitude for a comet `delta` AU from the observer and `r` AU from the Sun.
    ///
    /// The MPC's comet magnitude law is m = M1 + 5 log10 Δ + K1 log10 r, and CometEls.txt
    /// columns 92–95 / 97–100 carry G and k with the ephemeris service using
    /// m = G + 5 log10 Δ + 2.5 k log10 r: the file's slope is the small k (typically 4,
    /// i.e. K1 = 10), so it's multiplied by 2.5 here. (Skyfield reads the columns as
    /// magnitude_g / magnitude_k and computes no magnitude; the oracle uses this same law.)
    public func magnitude(delta: Double, r: Double) -> Double {
        elements.absoluteMagnitude + 5 * log10(delta) + 2.5 * elements.slope * log10(r)
    }

    /// Magnitude seen from Earth's centre, ignoring light time: cheap enough to
    /// filter a whole catalog with.
    public func magnitude(at date: Date) -> Double {
        let t = terrestrialTime(date)
        let e = Astronomy_HelioVector(BODY_EARTH, t)
        let h = elements.heliocentric(tt: t.tt)
        return magnitude(delta: simd_length(h - SIMD3(e.x, e.y, e.z)), r: simd_length(h))
    }
}

public enum CometCatalog {
    /// Where the MPC publishes the elements of every known comet (one line each,
    /// ~165 KB for ~1,000 comets; re-issued daily as orbits are improved).
    public static let sourceURL = URL(string: "https://minorplanetcenter.net/iau/MPCORB/CometEls.txt")!

    /// Parses the MPC one-line comet format
    /// (https://www.minorplanetcenter.net/iau/info/CometOrbitFormat.html). Lines that
    /// don't parse, or carry no magnitude parameters, are skipped; a designation seen
    /// twice keeps its first line.
    public static func parse(_ text: String) -> [Comet] {
        var seen = Set<String>(), out: [Comet] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let c = comet(String(line)), !seen.contains(c.id) else { continue }
            seen.insert(c.id)
            out.append(c)
        }
        return out
    }

    /// Comets predicted brighter than `limit` (geocentric, at `date`), brightest first.
    public static func bright(_ comets: [Comet], at date: Date, limit: Double = 12) -> [Comet] {
        comets.map { ($0, $0.magnitude(at: date)) }
            .filter { $0.1 < limit }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The seed shipped in the bundle: comets that could get brighter than about 14
    /// within two years of when it was cut (tools/gen-comets.py).
    public static let bundled: [Comet] = {
        let url = Bundle.module.url(forResource: "Resources", withExtension: nil)!.appendingPathComponent("comets-seed.txt")
        return (try? String(contentsOf: url, encoding: .ascii)).map(parse) ?? []
    }()

    static func comet(_ line: String) -> Comet? {
        let b = Array(line.utf8)
        func field(_ r: Range<Int>) -> String {
            guard r.lowerBound < b.count else { return "" }
            let s = String(decoding: b[r.lowerBound..<min(r.upperBound, b.count)], as: UTF8.self)
            return s.trimmingCharacters(in: .whitespaces)
        }
        func number(_ r: Range<Int>) -> Double? { Double(field(r)) }
        guard let py = Int(field(14..<18)), let pm = Int(field(19..<21)), let pd = number(22..<29),
              let q = number(30..<39), let e = number(41..<49),
              let w = number(51..<59), let node = number(61..<69), let inc = number(71..<79),
              let h = number(91..<95), let k = number(96..<100),
              q > 0, e >= 0
        else { return nil }
        let designation = field(102..<158)
        guard !designation.isEmpty else { return nil }
        var epoch = julianDaysTT(year: py, month: pm, day: pd)
        if let ey = Int(field(81..<85)), let em = Int(field(85..<87)), let ed = Int(field(87..<89)) {
            epoch = julianDaysTT(year: ey, month: em, day: Double(ed))
        }
        let (id, name) = splitDesignation(designation)
        let el = CometElements(perihelionTT: julianDaysTT(year: py, month: pm, day: pd),
                               perihelionDistance: q, eccentricity: e, argumentOfPerihelion: w,
                               longitudeOfNode: node, inclination: inc, epochTT: epoch,
                               absoluteMagnitude: h, slope: k)
        return Comet(id: id, name: name, displayName: designation, elements: el, line: line)
    }

    /// "C/2025 Y1 (ATLAS)" → ("C/2025 Y1", "ATLAS"); "2P/Encke" → ("2P", "Encke");
    /// "73P-BT/Schwassmann-Wachmann" → ("73P-BT", …); "A/2018 W3" → ("A/2018 W3", nil).
    static func splitDesignation(_ s: String) -> (String, String?) {
        if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
            let id = s[..<open].trimmingCharacters(in: .whitespaces)
            let name = s[s.index(after: open)..<s.index(before: s.endIndex)].trimmingCharacters(in: .whitespaces)
            return (id, name.isEmpty ? nil : name)
        }
        if let slash = s.firstIndex(of: "/"), let first = s.first, first.isNumber {
            let name = String(s[s.index(after: slash)...])
            return (String(s[..<slash]), name.isEmpty ? nil : name)
        }
        return (s, nil)
    }

    /// Days from J2000.0 (JD 2451545.0) of a Gregorian calendar date with a fractional day.
    static func julianDaysTT(year: Int, month: Int, day: Double) -> Double {
        // days-from-civil (H. Hinnant), shifted from 1970-01-01 (JD 2440587.5)
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days1970 = era * 146097 + doe - 719468
        return Double(days1970) + 2440587.5 - 2451545.0 + (day - 1)
    }
}

/// The instant on the TT scale, for orbits. Astronomy Engine derives TT from UT with
/// Espenak & Meeus's 2005 ΔT polynomial, which by 2026 runs ~6 s ahead of the real ΔT
/// (≈ 69.1 s; Earth's rotation sped up). The MPC's elements and Skyfield use
/// TT = UTC + 32.184 s + leap seconds; in 6 s the Earth moves 180 km, which shows
/// against the oracle. So from 2017 (the last leap second; none announced since) use
/// TT = UTC + 69.184 s, and Astronomy Engine's own before that.
func terrestrialTime(_ date: Date) -> astro_time_t {
    let days = date.timeIntervalSince1970 / 86400 - 10957.5
    guard days >= 6209.5 else { return astroTime(date) }     // 2017-01-01T00:00Z
    return Astronomy_TerrestrialTime(days + 69.184 / 86400)
}

public struct CometPosition: Sendable {
    public let comet: Comet
    /// Airless direction (light time and annual aberration applied).
    public let geometric: Horizontal
    /// Direction as seen through the atmosphere (refraction applied).
    public let apparent: Horizontal
    /// Predicted total magnitude (`Comet.magnitude(delta:r:)`); comet brightness
    /// forecasts are routinely a magnitude or two off either way.
    public let magnitude: Double
    /// Δ: from the observer, AU, light-time corrected.
    public let distanceAU: Double
    /// r: from the Sun, AU, when the light left.
    public let sunDistanceAU: Double
}

extension SkyFrame {
    /// Topocentric position of a comet: two-body heliocentric orbit, Sun and Earth from
    /// Astronomy Engine, light time iterated, then the frame's aberration and rotation
    /// (gravitational deflection, under 0.1″ away from the Sun's limb, is left out).
    public func position(of comet: Comet) -> CometPosition {
        var ut = astroTime(date)
        let t = terrestrialTime(date)
        // Earth heliocentric (Astronomy Engine's VSOP87 is ~1e-5 AU from DE421; its
        // barycentre adds the outer planets' error on top), the Sun's barycentric velocity
        // for the ~13 m/s it moves while the light is on its way
        let earth = Astronomy_HelioVector(BODY_EARTH, t)
        let sun = Astronomy_BaryState(BODY_SUN, t)
        let o = Astronomy_ObserverVector(&ut, observer.astro, EQUATOR_J2000)
        let here = SIMD3(earth.x + o.x, earth.y + o.y, earth.z + o.z)
        let sunVel = SIMD3(sun.vx, sun.vy, sun.vz)

        var tau = 0.0, helio = SIMD3<Double>(), rel = SIMD3<Double>()
        for _ in 0..<6 {
            helio = comet.elements.heliocentric(tt: t.tt - tau)
            rel = helio - sunVel * tau - here
            let next = simd_length(rel) / C_AUDAY
            let done = abs(next - tau) < 1e-12
            tau = next
            if done { break }
        }
        let geo = horizontal(star: simd_normalize(rel))
        let app = Horizontal(altitude: geo.altitude + refraction(atGeometricAltitude: geo.altitude), azimuth: geo.azimuth)
        let delta = simd_length(rel), r = simd_length(helio)
        return CometPosition(comet: comet, geometric: geo, apparent: app,
                             magnitude: comet.magnitude(delta: delta, r: r),
                             distanceAU: delta, sunDistanceAU: r)
    }

    /// Rises, sets and highest points of a comet over a window (horizon −0.5667°, as for points).
    public static func events(of comet: Comet, observer: Observer, from start: Date, to end: Date) -> Almanac.Events {
        Almanac.events(from: start, to: end, horizon: Almanac.horizon(for: nil)) {
            SkyFrame(date: $0, observer: observer).position(of: comet).geometric
        }
    }
}
