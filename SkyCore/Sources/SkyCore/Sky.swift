import CAstronomy
import Foundation
import simd

/// Where on Earth the sky is seen from. Degrees, metres; longitude east-positive.
public struct Observer: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var height: Double

    public init(latitude: Double, longitude: Double, height: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
    }

    var astro: astro_observer_t { Astronomy_MakeObserver(latitude, longitude, height) }
}

/// A direction in the local sky. Degrees: altitude above the horizon,
/// azimuth clockwise from true north (east = 90).
public struct Horizontal: Equatable, Sendable {
    public var altitude: Double
    public var azimuth: Double

    public init(altitude: Double, azimuth: Double) {
        self.altitude = altitude
        self.azimuth = azimuth
    }

    /// Unit vector in the horizon frame used everywhere in SkyCore:
    /// x = north, y = west, z = zenith (Astronomy Engine's HOR).
    public var vector: SIMD3<Double> {
        let a = altitude * .pi / 180, z = azimuth * .pi / 180
        return SIMD3(cos(a) * cos(z), -cos(a) * sin(z), sin(a))
    }

    public init(vector v: SIMD3<Double>) {
        let n = simd_normalize(v)
        altitude = asin(max(-1, min(1, n.z))) * 180 / .pi
        var az = atan2(-n.y, n.x) * 180 / .pi
        if az < 0 { az += 360 }
        azimuth = az
    }

    /// Great-circle separation in degrees.
    public func separation(from other: Horizontal) -> Double {
        let d = simd_dot(vector, other.vector)
        return acos(max(-1, min(1, d))) * 180 / .pi
    }
}

/// Atmospheric refraction in degrees to add to a geometric altitude
/// (standard conditions, the same model Astronomy Engine uses).
public func refraction(atGeometricAltitude alt: Double) -> Double {
    Astronomy_Refraction(REFRACTION_NORMAL, alt)
}

func astroTime(_ date: Date) -> astro_time_t {
    // Astronomy Engine counts UT days from 2000-01-01T12:00Z.
    Astronomy_TimeFromDays(date.timeIntervalSince1970 / 86400 - 10957.5)
}

/// The sky's orientation at one instant for one observer: the rotation that
/// takes J2000 equatorial unit vectors (the star catalog's frame) into the
/// horizon frame. Covers precession, nutation and Earth's rotation. Build one
/// per frame and every catalog star costs a single matrix multiply, plus the
/// aberration nudge (`apparent(_:)`, the same few flops in a shader).
public struct SkyFrame: Sendable {
    public let date: Date
    public let observer: Observer
    /// Column-major, applies as `eqjToHor * v`.
    public let eqjToHor: simd_double3x3
    /// Earth's barycentric velocity over the speed of light, J2000 frame.
    /// Annual aberration shifts every star up to ~20″ toward this.
    public let beta: SIMD3<Double>

    public init(date: Date, observer: Observer) {
        self.date = date
        self.observer = observer
        var t = astroTime(date)
        let r = Astronomy_Rotation_EQJ_HOR(&t, observer.astro)
        // astro_rotation_t.rot[i][j]: v'[j] = Σ_i rot[i][j] · v[i], so rot[i] is column i.
        let m = r.rot
        eqjToHor = simd_double3x3(columns: (
            SIMD3(m.0.0, m.0.1, m.0.2),
            SIMD3(m.1.0, m.1.1, m.1.2),
            SIMD3(m.2.0, m.2.1, m.2.2)))
        let earth = Astronomy_BaryState(BODY_EARTH, t)
        beta = SIMD3(earth.vx, earth.vy, earth.vz) / C_AUDAY
    }

    /// A catalog direction moved by annual aberration (first order).
    public func apparent(_ u: SIMD3<Double>) -> SIMD3<Double> {
        simd_normalize(u + beta - simd_dot(u, beta) * u)
    }

    /// Airless direction of a star, from its J2000 catalog direction.
    public func horizontal(star u: SIMD3<Double>) -> Horizontal {
        Horizontal(vector: eqjToHor * apparent(u))
    }

    /// Airless direction of a J2000 RA/Dec, in degrees.
    public func horizontal(raHours: Double, decDegrees: Double) -> Horizontal {
        horizontal(star: equatorialVector(raHours: raHours, decDegrees: decDegrees))
    }
}

/// J2000 equatorial unit vector (x toward the March equinox, z to the north pole).
public func equatorialVector(raHours: Double, decDegrees: Double) -> SIMD3<Double> {
    let ra = raHours * 15 * .pi / 180, dec = decDegrees * .pi / 180
    return SIMD3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
}
