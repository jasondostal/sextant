import CAstronomy
import Foundation
import simd

/// An annual meteor shower: when it's active, where its radiant is, how strong it gets.
///
/// Source: the International Meteor Organization's 2026 Meteor Shower Calendar
/// (J. Rendtel, ed., IMO INFO(3-25), https://www.imo.net/files/meteor-shower/cal2026.pdf),
/// Table 5, the Working List of Visual Meteor Showers (all of it but the Antihelion
/// Source, which has no single radiant). Solar longitudes are IMO's, equinox J2000.0, and
/// carry from year to year; IMO's activity dates were turned into λ☉ for 2026 (start at
/// 0h UT of the first day, end at 24h of the last). The peak radiant is Table 5's; the
/// daily drift is the least-squares line through IMO's Table 6 (radiant every 5 days)
/// pinned to it, except for the κ-Cygnids and September Lyncids, where Table 6 misses
/// Table 5's radiant by 5–7° and the free line's slope is used. Linear drift is good to
/// ~3° over a shower's activity (Table 6 is rounded to 1°, and some drifts curve).
/// Parent bodies aren't in the calendar: they're the established associations
/// (IAU Meteor Data Center), left nil where there isn't one.
/// tools/oracle/meteor_fixture.py holds the transcription the test checks this against.
public struct MeteorShower: Identifiable, Equatable, Sendable {
    /// IAU three-letter code, "PER".
    public let code: String
    /// IAU MDC number (7 for the Perseids).
    public let number: Int
    public let name: String
    /// Activity and maximum, solar longitude λ☉ in degrees (J2000).
    public let startLongitude: Double
    public let peakLongitude: Double
    public let endLongitude: Double
    /// Radiant at maximum, J2000 degrees.
    public let radiantRA: Double
    public let radiantDec: Double
    /// Radiant drift, degrees per day.
    public let driftRA: Double
    public let driftDec: Double
    /// Zenithal hourly rate at maximum; nil where IMO lists it as variable.
    public let zhr: Double?
    /// Atmospheric entry speed V∞, km/s.
    public let speed: Double
    /// Population index r (higher: more faint meteors).
    public let populationIndex: Double
    public let parentBody: String?

    public var id: String { code }

    /// Mean motion of the Sun in longitude, degrees per day.
    static let solarRate = 360 / 365.242189

    /// The instant of maximum in a calendar year (UTC): the first time at or after
    /// 1 January 0h that the Sun reaches the peak longitude. (Puppid-Velids: IMO's is a
    /// reference date for the radiant, not necessarily a true maximum.)
    public func peakDate(in year: Int) -> Date {
        let jan1 = Date(timeIntervalSince1970: 946_728_000 + 86400 *
                        CometCatalog.julianDaysTT(year: year, month: 1, day: 1))
        let ahead = (peakLongitude - Self.solarLongitude(at: jan1)).truncatingRemainder(dividingBy: 360)
        var t = jan1.addingTimeInterval(86400 * (ahead < 0 ? ahead + 360 : ahead) / Self.solarRate)
        for _ in 0..<6 {
            let miss = wrap180(peakLongitude - Self.solarLongitude(at: t))
            t = t.addingTimeInterval(86400 * miss / Self.solarRate)
            if abs(miss) < 1e-7 { break }
        }
        return t
    }

    /// Days from the nearest maximum (negative before it).
    public func daysFromPeak(at date: Date) -> Double {
        let year = Calendar.utc.component(.year, from: date)
        return [year - 1, year, year + 1]
            .map { date.timeIntervalSince(peakDate(in: $0)) / 86400 }
            .min { abs($0) < abs($1) }!
    }

    /// Whether the Sun's longitude is inside the activity window.
    public func isActive(on date: Date) -> Bool { isActive(longitude: Self.solarLongitude(at: date)) }

    func isActive(longitude lambda: Double) -> Bool {
        mod360(lambda - startLongitude) <= mod360(endLongitude - startLongitude)
    }

    /// The radiant on a date: the peak radiant moved by the daily drift. J2000.
    public func radiant(at date: Date) -> (raHours: Double, decDegrees: Double) {
        let days = daysFromPeak(at: date)
        let ra = mod360(radiantRA + driftRA * days) / 15
        return (ra, max(-90, min(90, radiantDec + driftDec * days)))
    }

    /// The showers active on a date, with how far each is from its maximum, in table order.
    public static func active(on date: Date) -> [(shower: MeteorShower, daysFromPeak: Double)] {
        let lambda = solarLongitude(at: date)
        return all.filter { $0.isActive(longitude: lambda) }
            .map { ($0, $0.daysFromPeak(at: date)) }
    }

    /// Solar longitude λ☉, degrees: the geometric geocentric Sun in ecliptic and equinox
    /// J2000, the convention of the IMO's tables. Not Astronomy Engine's SunPosition or
    /// SearchSunLongitude, which work in the true equinox of date (~0.36° apart by 2026).
    public static func solarLongitude(at date: Date) -> Double {
        let e = Astronomy_HelioVector(BODY_EARTH, terrestrialTime(date))
        let sun = equatorialToEcliptic(-SIMD3(e.x, e.y, e.z))
        return mod360(atan2(sun.y, sun.x) * 180 / .pi)
    }
}

func mod360(_ x: Double) -> Double {
    let r = x.truncatingRemainder(dividingBy: 360)
    return r < 0 ? r + 360 : r
}

func wrap180(_ x: Double) -> Double { mod360(x + 180) - 180 }

extension Calendar {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

extension MeteorShower {
    private init(_ code: String, _ number: Int, _ name: String, _ start: Double, _ peak: Double, _ end: Double,
                 _ ra: Double, _ dec: Double, _ dra: Double, _ ddec: Double, _ zhr: Double?,
                 _ speed: Double, _ r: Double, _ parent: String?) {
        self.init(code: code, number: number, name: name, startLongitude: start, peakLongitude: peak,
                  endLongitude: end, radiantRA: ra, radiantDec: dec, driftRA: dra, driftDec: ddec,
                  zhr: zhr, speed: speed, populationIndex: r, parentBody: parent)
    }

    /// IMO's working list, in order of maximum.
    public static let all: [MeteorShower] = [
        //  code   #   name                          start   peak    end      RA    Dec   ΔRA/d  ΔDec/d  ZHR  V∞   r    parent
        .init("QUA", 10, "Quadrantids", 276.1, 283.15, 292.4, 230, +49, 0.68, -0.19, 80, 41, 2.1, "(196256) 2003 EH1"),
        .init("GUM", 404, "γ-Ursae Minorids", 289.4, 298.0, 302.6, 228, +67, 0.80, -0.40, 3, 31, 3.0, nil),
        .init("ACE", 102, "α-Centaurids", 310.7, 319.4, 332.0, 211, -58, 1.21, -0.29, 6, 58, 2.0, nil),
        .init("LYR", 6, "April Lyrids", 23.7, 32.32, 40.3, 271, +34, 1.05, 0.00, 18, 49, 2.1, "C/1861 G1 (Thatcher)"),
        .init("PPU", 137, "π-Puppids", 24.7, 33.5, 38.3, 110, -45, 0.42, -0.09, nil, 18, 2.0, "26P/Grigg-Skjellerup"),
        .init("ETA", 31, "η-Aquariids", 28.6, 45.5, 67.3, 338, -1, 0.85, 0.40, 50, 66, 2.4, "1P/Halley"),
        .init("ELY", 145, "η-Lyrids", 42.2, 50.0, 53.8, 291, +43, 1.00, 0.10, 3, 43, 3.0, "C/1983 H1 (IRAS-Araki-Alcock)"),
        .init("ARI", 171, "Daytime Arietids", 52.9, 76.7, 93.1, 43, +24, 1.00, 0.00, 30, 38, 2.8, nil),
        .init("JBO", 170, "June Bootids", 90.3, 90.3, 100.7, 221, +48, 0.11, -0.11, nil, 18, 2.2, "7P/Pons-Winnecke"),
        .init("JPE", 175, "July Pegasids", 98.8, 108.0, 117.9, 347, +11, 0.86, 0.20, 3, 63, 3.0, nil),
        .init("GDR", 184, "July γ-Draconids", 121.7, 125.13, 128.4, 280, +51, 1.00, 0.00, 5, 27, 3.0, nil),
        .init("SDA", 5, "Southern δ-Aquariids", 109.3, 128.0, 150.5, 340, -16, 0.76, 0.24, 25, 41, 2.5, nil),
        .init("CAP", 1, "α-Capricornids", 100.7, 128.0, 142.8, 307, -10, 0.91, 0.27, 5, 23, 2.5, "169P/NEAT"),
        .init("ERI", 191, "η-Eridanids", 127.5, 135.0, 146.6, 41, -11, 0.90, 0.40, 3, 64, 3.0, "C/1852 K1 (Chacornac)"),
        .init("PER", 7, "Perseids", 114.1, 140.0, 151.5, 48, +58, 1.45, 0.21, 100, 59, 2.2, "109P/Swift-Tuttle"),
        .init("KCG", 12, "κ-Cygnids", 130.3, 144.0, 155.3, 286, +59, 0.50, 0.70, 3, 23, 3.0, nil),
        .init("AUR", 206, "Aurigids", 154.4, 158.6, 163.1, 91, +39, 1.05, -0.05, 6, 66, 2.5, "C/1911 N1 (Kiess)"),
        .init("SPE", 208, "September ε-Perseids", 162.1, 166.7, 178.6, 48, +40, 1.05, 0.07, 8, 64, 2.5, nil),
        .init("SLY", 81, "September Lyncids", 166.9, 170.0, 195.3, 113, +56, 1.32, -0.20, 3, 60, 3.0, nil),
        .init("DSX", 221, "Daytime Sextantids", 176.7, 188.0, 193.4, 156, -2, 0.80, 0.00, 5, 32, 2.5, "(155140) 2005 UD"),
        .init("OCT", 281, "October Camelopardalids", 191.4, 192.58, 193.4, 164, +79, 0.00, 0.00, 5, 47, 2.5, nil),
        .init("DRA", 9, "Draconids", 192.4, 195.4, 197.3, 262, +54, 0.00, 0.00, 5, 20, 2.6, "21P/Giacobini-Zinner"),
        .init("EGE", 23, "ε-Geminids", 200.3, 205.0, 214.2, 102, +27, 1.00, 0.00, 3, 70, 3.0, nil),
        .init("ORI", 8, "Orionids", 188.5, 208.0, 225.2, 95, +16, 0.64, 0.09, 20, 66, 2.5, "1P/Halley"),
        .init("LMI", 22, "Leonis Minorids", 205.3, 211.0, 214.2, 162, +37, 1.00, -0.40, 2, 62, 3.0, "C/1739 K1 (Zanotti)"),
        .init("STA", 2, "Southern Taurids", 176.7, 223.0, 238.3, 52, +15, 0.76, 0.19, 7, 27, 2.3, "2P/Encke"),
        .init("NTA", 17, "Northern Taurids", 206.2, 230.0, 258.6, 58, +22, 0.87, 0.16, 5, 29, 2.3, "2P/Encke"),
        .init("LEO", 13, "Leonids", 223.2, 235.27, 248.4, 152, +22, 0.59, -0.26, 15, 71, 2.5, "55P/Tempel-Tuttle"),
        .init("AMO", 246, "α-Monocerotids", 232.3, 239.32, 243.4, 117, +1, 0.80, -0.20, nil, 65, 2.4, nil),
        .init("NOO", 250, "November Orionids", 230.2, 246.0, 254.5, 91, +16, 0.76, 0.00, 3, 44, 3.0, nil),
        .init("PHO", 254, "Phoenicids", 248.4, 249.5, 253.5, 8, -27, 0.63, -0.10, nil, 15, 2.8, "289P/Blanpain"),
        .init("PUP", 301, "Puppid-Velids", 248.4, 255.0, 263.7, 123, -45, 0.60, 0.00, 10, 44, 2.9, nil),
        .init("MON", 19, "Monocerotids", 248.4, 257.0, 267.7, 100, +8, 0.70, -0.20, 3, 41, 3.0, "C/1917 F1 (Mellish)"),
        .init("HYD", 16, "σ-Hydrids", 250.4, 257.0, 268.7, 125, +2, 0.80, -0.20, 7, 58, 3.0, nil),
        .init("GEM", 4, "Geminids", 251.5, 262.2, 268.7, 112, +33, 1.00, -0.06, 150, 35, 2.6, "(3200) Phaethon"),
        .init("URS", 15, "Ursids", 264.7, 270.7, 274.9, 217, +76, 0.00, -0.40, 10, 33, 2.8, "8P/Tuttle"),
        .init("COM", 20, "Comae Berenicids", 251.5, 271.0, 310.5, 164, +29, 0.91, -0.36, 3, 65, 3.0, nil),
    ]
}
