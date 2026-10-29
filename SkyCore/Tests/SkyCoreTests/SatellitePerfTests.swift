import Foundation
import XCTest
@testable import SkyCore

/// Not a gate: prints how long the full catalog takes, to size the app's
/// coarse/fine passes. Skipped unless the CelesTrak cache is present.
final class SatellitePerfTests: XCTestCase {
    func testFullCatalogTiming() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/ducktyping-sky")
        guard let active = try? Data(contentsOf: dir.appendingPathComponent("gp-active.json")),
              let visual = try? Data(contentsOf: dir.appendingPathComponent("gp-visual.json")) else {
            throw XCTSkip("no CelesTrak cache")
        }
        var t = Date()
        let cat = try SatelliteCatalog(groups: [visual, active])
        let build = Date().timeIntervalSince(t)
        let frame = SatelliteFrame(date: Date(), observer: Observer(latitude: 44.52, longitude: -89.57))
        t = Date()
        var up = 0, lit = 0
        for s in cat.satellites {
            if let p = frame.position(of: s), p.horizontal.altitude > 0 {
                up += 1
                if p.sunlit { lit += 1 }
            }
        }
        let prop = Date().timeIntervalSince(t)
        print(String(format: "catalog: %d sats, build %.0f ms, propagate all %.1f ms (%.2f µs each), %d up, %d up+sunlit",
                     cat.satellites.count, build * 1000, prop * 1000, prop / Double(cat.satellites.count) * 1e6, up, lit))
    }
}
