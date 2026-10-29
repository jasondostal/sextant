import Foundation
import XCTest
@testable import SkyCore

/// Hard gate: SkyCore's SGP4 (SatelliteKit) + TEME→topocentric chain must put
/// satellites where Skyfield does, from the same OMM records. Fixtures come from
/// tools/oracle/sat_fixture.py (12 satellites incl. two deep-space, 2 places,
/// 6 instants from −6 h to +36 h of epoch).
final class SatelliteOracleTests: XCTestCase {
    struct Case: Decodable {
        let place: String, lat: Double, lon: Double, height: Double, utc: String
        let id: Int, alt: Double, az: Double, rangeKm: Double, sunlit: Bool
    }

    struct Fixture: Decodable { let cases: [Case] }

    /// Arcminutes, for objects above the horizon (where it matters).
    static let directionTolerance = 0.25
    static let rangeToleranceKm = 0.25

    var cases: [Case] = []
    var sats: [Int: Satellite] = [:]

    override func setUpWithError() throws {
        let url = Bundle.module.url(forResource: "Fixtures/satellites", withExtension: "json")!
        let data = try Data(contentsOf: url)
        cases = try JSONDecoder().decode(Fixture.self, from: data).cases
        let elements = try JSONSerialization.data(
            withJSONObject: (try JSONSerialization.jsonObject(with: data) as! [String: Any])["elements"]!)
        let catalog = try SatelliteCatalog(groups: [elements], keepAll: true)
        sats = Dictionary(uniqueKeysWithValues: catalog.satellites.map { ($0.id, $0) })
    }

    func testPositionsMatchSkyfield() throws {
        var worst = (0.0, ""), worstRange = (0.0, ""), shadowMismatch: [String] = []
        for c in cases {
            let sat = try XCTUnwrap(sats[c.id], "\(c.id) missing")
            let frame = SatelliteFrame(date: ISO8601DateFormatter().date(from: c.utc)!,
                                       observer: Observer(latitude: c.lat, longitude: c.lon, height: c.height))
            let p = try XCTUnwrap(frame.position(of: sat), "\(sat.name) failed to propagate")
            let label = "\(sat.name) @ \(c.place) \(c.utc)"
            let dr = abs(p.rangeKm - c.rangeKm)
            if dr > worstRange.0 { worstRange = (dr, label) }
            XCTAssertLessThan(dr, Self.rangeToleranceKm, "range " + label)
            if p.sunlit != c.sunlit { shadowMismatch.append(label) }
            guard c.alt > 0 else { continue }
            let err = p.horizontal.separation(from: Horizontal(altitude: c.alt, azimuth: c.az)) * 60
            if err > worst.0 { worst = (err, label) }
            XCTAssertLessThan(err, Self.directionTolerance, label)
        }
        // the shadow model is a cylinder vs Skyfield's ephemeris-based test:
        // they may only disagree right at the shadow edge, so allow a stray one
        XCTAssertLessThanOrEqual(shadowMismatch.count, 1, "sunlit disagrees: \(shadowMismatch)")
        print(String(format: "satellites: worst direction %.3f′ (%@), worst range %.3f km (%@), shadow mismatches %d",
                     worst.0, worst.1, worstRange.0, worstRange.1, shadowMismatch.count))
    }
}
