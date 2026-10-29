import CAstronomy
import Foundation

/// The solar-system objects SkyCore places in the sky.
public enum Body: String, CaseIterable, Sendable {
    case sun = "Sun", moon = "Moon"
    case mercury = "Mercury", venus = "Venus", mars = "Mars"
    case jupiter = "Jupiter", saturn = "Saturn", uranus = "Uranus", neptune = "Neptune"

    var astro: astro_body_t {
        switch self {
        case .sun: BODY_SUN
        case .moon: BODY_MOON
        case .mercury: BODY_MERCURY
        case .venus: BODY_VENUS
        case .mars: BODY_MARS
        case .jupiter: BODY_JUPITER
        case .saturn: BODY_SATURN
        case .uranus: BODY_URANUS
        case .neptune: BODY_NEPTUNE
        }
    }
}

public struct BodyPosition: Sendable {
    public let body: Body
    /// Airless direction.
    public let geometric: Horizontal
    /// Direction as seen through the atmosphere (refraction applied).
    public let apparent: Horizontal
    public let magnitude: Double
    /// Illuminated fraction of the disc, 0…1.
    public let phase: Double
    public let distanceAU: Double
}

extension SkyFrame {
    /// Topocentric position of a body, corrected for light time and aberration.
    public func position(of body: Body) -> BodyPosition {
        var t = astroTime(date)
        let eq = Astronomy_Equator(body.astro, &t, observer.astro, EQUATOR_OF_DATE, ABERRATION)
        let geo = Astronomy_Horizon(&t, observer.astro, eq.ra, eq.dec, REFRACTION_NONE)
        let app = Astronomy_Horizon(&t, observer.astro, eq.ra, eq.dec, REFRACTION_NORMAL)
        let mag: Double, phase: Double
        if body == .sun {
            mag = -26.74
            phase = 1
        } else {
            let ill = Astronomy_Illumination(body.astro, t)
            mag = ill.mag
            phase = ill.phase_fraction
        }
        return BodyPosition(
            body: body,
            geometric: Horizontal(altitude: geo.altitude, azimuth: geo.azimuth),
            apparent: Horizontal(altitude: app.altitude, azimuth: app.azimuth),
            magnitude: mag, phase: phase, distanceAU: eq.dist)
    }
}
