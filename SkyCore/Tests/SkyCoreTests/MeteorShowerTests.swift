import Foundation
import simd
import XCTest
@testable import SkyCore

/// Hard gate: the meteor-shower table must say what the IMO 2026 calendar says, and
/// its dates must come out where Skyfield puts the Sun. Fixture from
/// tools/oracle/meteor_fixture.py (its own transcription of IMO Tables 5 and 6).
final class MeteorShowerTests: XCTestCase {
    struct Node: Decodable { let utc: String; let ra: Double; let dec: Double }
    struct Shower: Decodable {
        let code: String, peakLongitude: Double, imoPeakDate: String, peak: String
        let startLongitude: Double, endLongitude: Double, start: String, end: String
        let nodes: [Node], driftRA: Double, driftDec: Double
        let ra: Double, dec: Double, tablesDisagree: Bool
    }
    struct Fixture: Decodable { let year: Int; let showers: [Shower] }

    // Seconds, degrees. Ratcheted 2026-11-06 to just above the measured worst.
    // Peak: 47 s, which is Astronomy Engine's Earth again (6–10e-6 AU from DE421 is
    // ~2″ of solar longitude, and the Sun takes ~50 s to move 2″); IMO's maxima are
    // quoted to 0.01° at best (~15 min), so it's far below what the data means.
    // Radiant: 2.80°, the α-Capricornids, whose drift curves (Table 6 is rounded to 1°
    // too); 1.17° for the node-to-node motion of the two showers IMO's tables disagree on.
    static let peakTime = 50.0
    static let radiant = 3.0

    var fixture: Fixture!
    var table: [String: MeteorShower] = [:]

    override func setUpWithError() throws {
        let url = Bundle.module.url(forResource: "Fixtures/meteors", withExtension: "json")!
        fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        table = Dictionary(uniqueKeysWithValues: MeteorShower.all.map { ($0.code, $0) })
    }

    func testTableMatchesTheCalendar() throws {
        XCTAssertEqual(Set(table.keys), Set(fixture.showers.map(\.code)))
        // in order of maximum through the calendar year (it opens with the Quadrantids at 283°)
        let fromJanuary = MeteorShower.all.map { mod360($0.peakLongitude - 280) }
        XCTAssertEqual(fromJanuary, fromJanuary.sorted(), "in order of maximum")
        for f in fixture.showers {
            let s = try XCTUnwrap(table[f.code])
            XCTAssertEqual(s.peakLongitude, f.peakLongitude, f.code)
            XCTAssertEqual(s.radiantRA, f.ra, "RA " + f.code)
            XCTAssertEqual(s.radiantDec, f.dec, "Dec " + f.code)
            // activity λ☉ are rounded to 0.1°, drifts to 0.01°/day
            XCTAssertEqual(s.startLongitude, f.startLongitude, accuracy: 0.05, "start " + f.code)
            XCTAssertEqual(s.endLongitude, f.endLongitude, accuracy: 0.05, "end " + f.code)
            XCTAssertEqual(s.driftRA, f.driftRA, accuracy: 0.005, "ΔRA " + f.code)
            XCTAssertEqual(s.driftDec, f.driftDec, accuracy: 0.005, "ΔDec " + f.code)
        }
    }

    func testPeakDatesMatchSkyfieldAndIMO() throws {
        var worst = (0.0, "")
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone(identifier: "UTC")
        for f in fixture.showers {
            let s = try XCTUnwrap(table[f.code])
            let ours = s.peakDate(in: fixture.year)
            let gap = abs(ours.timeIntervalSince(AlmanacOracleTests.date(f.peak)))
            if gap > worst.0 { worst = (gap, f.code) }
            XCTAssertLessThan(gap, Self.peakTime, "peak " + f.code)
            XCTAssertEqual(day.string(from: ours), f.imoPeakDate, "IMO's printed maximum date, " + f.code)
            XCTAssertEqual(MeteorShower.solarLongitude(at: ours), s.peakLongitude, accuracy: 1e-6)
            // a year on, the same longitude a year later
            let next = s.peakDate(in: fixture.year + 1).timeIntervalSince(ours) / 86400
            XCTAssertEqual(next, 365.2422, accuracy: 0.03, "year to year " + f.code)
        }
        print(String(format: "meteor peaks: worst %.2f s (%@) from Skyfield", worst.0, worst.1))
    }

    func testActivityWindows() throws {
        for f in fixture.showers {
            let s = try XCTUnwrap(table[f.code])
            let start = AlmanacOracleTests.date(f.start), end = AlmanacOracleTests.date(f.end)
            // the rounding to 0.1° moves the edges by up to 1.2 h
            XCTAssertTrue(s.isActive(on: start.addingTimeInterval(3 * 3600)), "just after start " + f.code)
            XCTAssertTrue(s.isActive(on: end.addingTimeInterval(-3 * 3600)), "just before end " + f.code)
            XCTAssertFalse(s.isActive(on: start.addingTimeInterval(-3 * 3600)), "before start " + f.code)
            XCTAssertFalse(s.isActive(on: end.addingTimeInterval(3 * 3600)), "after end " + f.code)
            let peak = s.peakDate(in: fixture.year)
            let listed = MeteorShower.active(on: peak).first { $0.shower.code == f.code }
            XCTAssertEqual(try XCTUnwrap(listed, "active at peak " + f.code).daysFromPeak, 0, accuracy: 1e-6)
        }
        // Perseids, three days before their maximum, across the year boundary for the Quadrantids
        let per = try XCTUnwrap(table["PER"]), qua = try XCTUnwrap(table["QUA"])
        let aug10 = per.peakDate(in: 2026).addingTimeInterval(-3 * 86400)
        XCTAssertEqual(per.daysFromPeak(at: aug10), -3, accuracy: 1e-6)
        let dec31 = qua.peakDate(in: 2026).addingTimeInterval(-3 * 86400)
        XCTAssertEqual(qua.daysFromPeak(at: dec31), -3, accuracy: 1e-6)
        XCTAssertTrue(MeteorShower.active(on: dec31).contains { $0.shower.code == "QUA" })
    }

    func testRadiantDriftFollowsTable6() throws {
        var worst = (0.0, ""), worstMotion = (0.0, "")
        for f in fixture.showers {
            let s = try XCTUnwrap(table[f.code])
            let atPeak = s.radiant(at: s.peakDate(in: fixture.year))
            XCTAssertEqual(atPeak.raHours, s.radiantRA / 15, accuracy: 1e-9)
            XCTAssertEqual(atPeak.decDegrees, s.radiantDec, accuracy: 1e-9)
            guard !f.tablesDisagree else {
                // IMO's two tables disagree here: Table 5 puts the κ-Cygnid radiant at +59° on
                // Aug 17, Table 6 at ~+54°; the September Lyncids +56° vs ~+49°. Table 5 sets
                // the position, Table 6 the motion: check the motion from node to node
                let n0 = try XCTUnwrap(f.nodes.first)
                let r0 = s.radiant(at: AlmanacOracleTests.date(n0.utc))
                for n in f.nodes.dropFirst() {
                    let r = s.radiant(at: AlmanacOracleTests.date(n.utc))
                    let cosDec = cos(n.dec * .pi / 180)
                    let dra = (wrap180((r.raHours - r0.raHours) * 15) - wrap180(n.ra - n0.ra)) * cosDec
                    let ddec = (r.decDegrees - r0.decDegrees) - (n.dec - n0.dec)
                    let miss = (dra * dra + ddec * ddec).squareRoot()
                    if miss > worstMotion.0 { worstMotion = (miss, "\(f.code) \(n.utc.prefix(10))") }
                    XCTAssertLessThan(miss, Self.radiant, "\(f.code) radiant motion to \(n.utc.prefix(10))")
                }
                continue
            }
            for n in f.nodes {
                let r = s.radiant(at: AlmanacOracleTests.date(n.utc))
                let ours = equatorialVector(raHours: r.raHours, decDegrees: r.decDegrees)
                let theirs = equatorialVector(raHours: n.ra / 15, decDegrees: n.dec)
                let sep = acos(max(-1, min(1, simd_dot(ours, theirs)))) * 180 / .pi
                if sep > worst.0 { worst = (sep, "\(f.code) \(n.utc.prefix(10))") }
                XCTAssertLessThan(sep, Self.radiant, "\(f.code) radiant on \(n.utc.prefix(10))")
            }
        }
        print(String(format: "meteor radiants: worst %.2f° from IMO Table 6 (%@); KCG/SLY motion %.2f° (%@)",
                     worst.0, worst.1, worstMotion.0, worstMotion.1))
    }
}
