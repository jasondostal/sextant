import Foundation
import XCTest
@testable import SkyCore

/// Hard gate: SkyCore's two-body comet propagation and topocentric chain must put
/// comets where Skyfield does, from the same MPC lines. Fixtures come from
/// tools/oracle/comet_fixture.py: 11 comets (e from 0.60 to 6.1, three within 0.003
/// of 1 and one exact parabola), Stevens Point and Sydney, 9 instants over ±1 year
/// of 2026-11-06; and rise / set / transit for two comets on two days at each place.
final class CometOracleTests: XCTestCase {
    struct Case: Decodable {
        let place: String, lat: Double, lon: Double, height: Double, utc: String
        let designation: String, alt: Double, az: Double, delta: Double, r: Double, mag: Double
    }
    struct Peak: Decodable { let t: String; let alt: Double }
    struct Day: Decodable {
        let place: String, lat: Double, lon: Double, height: Double, start: String, end: String
        let designation: String, rises: [String], sets: [String], peaks: [Peak]
    }
    struct Fixture: Decodable { let lines: [String]; let cases: [Case]; let almanac: [Day] }

    // Arcminutes, AU, magnitudes; seconds and arcminutes for the almanac. Ratcheted
    // 2026-11-06 to just above the measured worst: 0.041′, Δ 8.9e-6 AU, r 1.2e-9 AU,
    // 0.00002 mag; 0.13 s, 0.20 s, 0.008′.
    // r is the comet model alone and agrees to a few hundred metres. Δ and direction
    // carry Astronomy Engine's Earth (truncated VSOP87), measured 6–10e-6 AU from DE421's
    // on the fixture dates: that, not the comet, is the 9e-6 AU (and the 2.5″).
    static let direction = 0.05
    static let delta = 1e-5
    static let sunDistance = 5e-9
    static let magnitude = 0.001
    static let crossing = 0.5
    static let peakTime = 0.5
    static let peakAlt = 0.02

    var fixture: Fixture!
    var comets: [String: Comet] = [:]

    override func setUpWithError() throws {
        let url = Bundle.module.url(forResource: "Fixtures/comets", withExtension: "json")!
        fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let parsed = CometCatalog.parse(fixture.lines.joined(separator: "\n"))
        XCTAssertEqual(parsed.count, fixture.lines.count, "every fixture line parses")
        comets = Dictionary(uniqueKeysWithValues: parsed.map { ($0.displayName, $0) })
    }

    func testPositionsMatchSkyfield() throws {
        var worst = (0.0, ""), worstDelta = (0.0, ""), worstR = (0.0, ""), worstMag = (0.0, "")
        for c in fixture.cases {
            let comet = try XCTUnwrap(comets[c.designation], c.designation)
            let frame = SkyFrame(date: ISO8601DateFormatter().date(from: c.utc)!,
                                 observer: Observer(latitude: c.lat, longitude: c.lon, height: c.height))
            let p = frame.position(of: comet)
            let label = "\(c.designation) @ \(c.place) \(c.utc)"
            let err = p.geometric.separation(from: Horizontal(altitude: c.alt, azimuth: c.az)) * 60
            let dd = abs(p.distanceAU - c.delta), dr = abs(p.sunDistanceAU - c.r), dm = abs(p.magnitude - c.mag)
            if err > worst.0 { worst = (err, label) }
            if dd > worstDelta.0 { worstDelta = (dd, label) }
            if dr > worstR.0 { worstR = (dr, label) }
            if dm > worstMag.0 { worstMag = (dm, label) }
            XCTAssertLessThan(err, Self.direction, "direction " + label)
            XCTAssertLessThan(dd, Self.delta, "Δ " + label)
            XCTAssertLessThan(dr, Self.sunDistance, "r " + label)
            XCTAssertLessThan(dm, Self.magnitude, "magnitude " + label)
        }
        print(String(format: "comets: %d cases; worst direction %.4f′ (%@), Δ %.2e AU (%@), r %.2e AU (%@), mag %.5f (%@)",
                     fixture.cases.count, worst.0, worst.1, worstDelta.0, worstDelta.1,
                     worstR.0, worstR.1, worstMag.0, worstMag.1))
    }

    func testRiseSetMatchesSkyfield() throws {
        var worstCross = (0.0, ""), worstPeakT = (0.0, ""), worstPeakA = (0.0, "")
        let date = AlmanacOracleTests.date
        for d in fixture.almanac {
            let comet = try XCTUnwrap(comets[d.designation])
            let obs = Observer(latitude: d.lat, longitude: d.lon, height: d.height)
            let ev = SkyFrame.events(of: comet, observer: obs, from: date(d.start), to: date(d.end))
            let label = "\(d.designation) @ \(d.place) \(d.start.prefix(10))"
            XCTAssertEqual(ev.rises.count, d.rises.count, "rises " + label)
            XCTAssertEqual(ev.sets.count, d.sets.count, "sets " + label)
            for (e, ours) in zip(d.rises + d.sets, ev.rises + ev.sets) {
                let gap = abs(ours.date.timeIntervalSince(date(e)))
                if gap > worstCross.0 { worstCross = (gap, label) }
                XCTAssertLessThan(gap, Self.crossing, "crossing " + label)
            }
            XCTAssertEqual(ev.peaks.count, d.peaks.count, "peaks " + label)
            for (e, ours) in zip(d.peaks, ev.peaks) {
                let dt = abs(ours.date.timeIntervalSince(date(e.t)))
                let da = abs(ours.horizontal.altitude - e.alt) * 60
                if dt > worstPeakT.0 { worstPeakT = (dt, label) }
                if da > worstPeakA.0 { worstPeakA = (da, label) }
                XCTAssertLessThan(dt, Self.peakTime, "peak time " + label)
                XCTAssertLessThan(da, Self.peakAlt, "peak altitude " + label)
            }
        }
        print(String(format: "comet almanac: worst crossing %.2f s (%@), peak time %.2f s (%@), peak alt %.3f′ (%@)",
                     worstCross.0, worstCross.1, worstPeakT.0, worstPeakT.1, worstPeakA.0, worstPeakA.1))
    }

    func testParsesTheMPCFormat() throws {
        let encke = try XCTUnwrap(comets["2P/Encke"])
        XCTAssertEqual(encke.id, "2P")
        XCTAssertEqual(encke.name, "Encke")
        XCTAssertEqual(encke.elements.perihelionDistance, 0.338596)
        XCTAssertEqual(encke.elements.eccentricity, 0.847324)
        XCTAssertEqual(encke.elements.absoluteMagnitude, 14.6)
        XCTAssertEqual(encke.elements.slope, 4.0)
        // 2027-02-10.2280 TT is JD 2461446.7280
        XCTAssertEqual(encke.elements.perihelionTT, 2461446.7280 - 2451545, accuracy: 1e-9)
        let swan = try XCTUnwrap(comets["C/2026 P3 (SWAN)"])
        XCTAssertEqual(swan.id, "C/2026 P3")
        XCTAssertEqual(swan.name, "SWAN")
        XCTAssertEqual(CometCatalog.splitDesignation("73P-BT/Schwassmann-Wachmann").0, "73P-BT")
        XCTAssertEqual(CometCatalog.splitDesignation("A/2018 W3").0, "A/2018 W3")
        XCTAssertNil(CometCatalog.splitDesignation("A/2018 W3").1)
    }

    func testBundledSeed() throws {
        let seed = CometCatalog.bundled
        XCTAssertGreaterThan(seed.count, 20)
        XCTAssertEqual(Set(seed.map(\.id)).count, seed.count, "ids unique")
        // every fixture comet that came from the seed parses identically from the bundle
        let byLine = Dictionary(uniqueKeysWithValues: seed.map { ($0.line, $0) })
        for line in fixture.lines.prefix(8) {
            XCTAssertNotNil(byLine[line], "seed has \(line.prefix(40))")
        }
        let bright = CometCatalog.bright(seed, at: Date(timeIntervalSince1970: 1_793_000_000), limit: 12)
        let mags = bright.map { $0.magnitude(at: Date(timeIntervalSince1970: 1_793_000_000)) }
        XCTAssertEqual(mags, mags.sorted(), "brightest first")
        XCTAssertTrue(mags.allSatisfy { $0 < 12 })
    }

    /// The solver at the edges it has to get right: e a hair either side of 1, far from
    /// perihelion, and decades out on a hyperbola. Checked against the conserved
    /// energy and angular momentum of the two-body orbit.
    func testKeplerSolverConservesTheOrbit() {
        let mu = Kepler.mu
        for e in [0.0, 0.3, 0.9, 0.99, 0.999999, 1.0, 1.000001, 1.01, 1.5, 6.14] {
            let q = 0.8
            let h = (mu * q * (1 + e)).squareRoot()
            let energy = -mu * (1 - e) / (2 * q)
            for dt in [-36500.0, -3650, -400, -30, -1, -1e-3, 0, 1e-3, 1, 30, 400, 3650, 36500] {
                let (x, y) = Kepler.perifocal(q: q, e: e, dt: dt)
                // velocity by central difference: the step grows with dt on open orbits so the
                // solver's rounding (~1e-15 of dt) stays small against it; ellipses are reduced
                // to within half a period of perihelion, and a long step would cut the curve
                let step = e < 1 ? 1e-3 : max(1e-3, abs(dt) * 1e-5)
                let (x2, y2) = Kepler.perifocal(q: q, e: e, dt: dt + step)
                let (x0, y0) = Kepler.perifocal(q: q, e: e, dt: dt - step)
                let vx = (x2 - x0) / (2 * step), vy = (y2 - y0) / (2 * step)
                let r = (x * x + y * y).squareRoot()
                let label = "e=\(e) dt=\(dt)"
                XCTAssertEqual((x * vy - y * vx) / h, 1, accuracy: 1e-7, "angular momentum " + label)
                let kinetic = (vx * vx + vy * vy) / 2
                XCTAssertEqual(kinetic - mu / r, energy, accuracy: 1e-7 * (kinetic + mu / r), "energy " + label)
                // the conic itself: r = p / (1 + e cos ν)
                let nu = atan2(y, x)
                XCTAssertEqual(r * (1 + e * cos(nu)), q * (1 + e), accuracy: 1e-10 * max(1, r), "conic " + label)
                if dt == 0 { XCTAssertEqual(x, q, accuracy: 1e-15); XCTAssertEqual(y, 0, accuracy: 1e-15) }
                // (short-period ellipses wrap round within the dt range: only the long ones)
                if dt != 0, e >= 0.99 { XCTAssertEqual(y > 0, dt > 0, "direction of travel " + label) }
            }
        }
    }
}
