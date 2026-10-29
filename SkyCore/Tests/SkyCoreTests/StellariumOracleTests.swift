import Foundation
import XCTest
import simd
@testable import SkyCore

/// Hard gate: SkyCore must put every fixture object where Stellarium 26.3 does.
/// Fixtures come from tools/oracle/stellarium_fixture.py (4 places × 4 instants
/// × 16 stars + 9 bodies). Tolerances are the gate; don't loosen one to make a
/// red test green — find out which side is wrong first.
final class StellariumOracleTests: XCTestCase {
    struct Case: Decodable {
        let place: String, lat: Double, lon: Double, height: Double
        let utc: String, object: String, kind: String
        let alt: Double, az: Double, altGeometric: Double
    }

    struct Fixture: Decodable { let cases: [Case] }

    /// Arcminutes.
    static let geometricTolerance = 0.5
    /// Refraction models differ slightly; compared only well above the horizon.
    static let apparentTolerance = 0.5
    static let apparentMinAltitude = 5.0

    var cases: [Case] = []
    var sky: SkyData!

    override func setUpWithError() throws {
        let url = Bundle.module.url(forResource: "Fixtures/stellarium", withExtension: "json")!
        cases = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases
        sky = try SkyData.load()
    }

    func frame(_ c: Case) -> SkyFrame {
        SkyFrame(date: ISO8601DateFormatter().date(from: c.utc)!,
                 observer: Observer(latitude: c.lat, longitude: c.lon, height: c.height))
    }

    func label(_ c: Case) -> String { "\(c.object) @ \(c.place) \(c.utc)" }

    func testStarsMatchStellarium() throws {
        var worst = (0.0, ""), worstApparent = (0.0, "")
        for c in cases where c.kind == "star" {
            let i = try XCTUnwrap(sky.catalog.index(named: c.object), "\(c.object) not in catalog")
            let geo = frame(c).horizontal(star: SIMD3<Double>(sky.catalog.stars[i].direction))
            let err = geo.separation(from: Horizontal(altitude: c.altGeometric, azimuth: c.az)) * 60
            if err > worst.0 { worst = (err, label(c)) }
            XCTAssertLessThan(err, Self.geometricTolerance, label(c))
            if c.alt > Self.apparentMinAltitude {
                let app = geo.altitude + refraction(atGeometricAltitude: geo.altitude)
                let e = abs(app - c.alt) * 60
                if e > worstApparent.0 { worstApparent = (e, label(c)) }
                XCTAssertLessThan(e, Self.apparentTolerance, "apparent " + label(c))
            }
        }
        print(String(format: "stars: worst geometric %.3f′ (%@), worst apparent alt %.3f′ (%@)",
                     worst.0, worst.1, worstApparent.0, worstApparent.1))
    }

    func testBodiesMatchStellarium() throws {
        var worst: [String: (Double, String)] = [:]
        for c in cases where c.kind == "body" {
            let body = try XCTUnwrap(Body(rawValue: c.object))
            let p = frame(c).position(of: body)
            let err = p.geometric.separation(from: Horizontal(altitude: c.altGeometric, azimuth: c.az)) * 60
            if err > (worst[c.object]?.0 ?? -1) { worst[c.object] = (err, c.place + " " + c.utc) }
            XCTAssertLessThan(err, Self.geometricTolerance, label(c))
            if c.alt > Self.apparentMinAltitude {
                XCTAssertLessThan(abs(p.apparent.altitude - c.alt) * 60, Self.apparentTolerance, "apparent " + label(c))
            }
        }
        for (name, w) in worst.sorted(by: { $0.key < $1.key }) {
            print(String(format: "%@: worst %.3f′ (%@)", name, w.0, w.1))
        }
    }
}
