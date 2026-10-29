import Foundation
import XCTest
@testable import SkyCore

/// Hard gate: rise, set and transit times, and satellite passes, must agree with
/// Skyfield. Fixtures come from tools/oracle/almanac_fixture.py: 9 bodies at
/// Stevens Point, Sydney and Tromsø (polar day and night) on 5 dates, and every
/// pass of the 12 position-oracle satellites over 24 h from their epochs.
final class AlmanacOracleTests: XCTestCase {
    struct Peak: Decodable { let t: String; let alt: Double }
    struct BodyDay: Decodable {
        let place: String, lat: Double, lon: Double, height: Double, start: String, end: String
        let body: String, rises: [String], sets: [String], peaks: [Peak]
    }
    struct Pass: Decodable { let rise: String; let set: String; let peaks: [Peak] }
    struct SatDay: Decodable { let id: Int; let start: String; let end: String; let passes: [Pass] }
    struct Place: Decodable { let lat: Double; let lon: Double; let height: Double }
    struct Fixture: Decodable { let place: Place; let bodies: [BodyDay]; let satellites: [SatDay] }

    // seconds, and arcminutes for altitudes
    // (ratcheted 2026-10-29 from 30 s / 120 s / 1′ / 2 s / 5 s / 0.5′ to just above the measured
    // worst: 6.6 s / 1.3 s / 0.23′ / 0.27 s / 0.24 s / 0.27′)
    static let bodyCrossing = 10.0
    static let bodyPeakTime = 5.0
    static let bodyPeakAlt = 0.35
    static let satCrossing = 0.5
    static let satPeakTime = 0.5
    static let satPeakAlt = 0.35

    var fixture: Fixture!
    var sats: [Int: Satellite] = [:]

    override func setUpWithError() throws {
        let url = Bundle.module.url(forResource: "Fixtures/almanac", withExtension: "json")!
        fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let satURL = Bundle.module.url(forResource: "Fixtures/satellites", withExtension: "json")!
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: satURL)) as! [String: Any]
        let catalog = try SatelliteCatalog(groups: [JSONSerialization.data(withJSONObject: raw["elements"]!)], keepAll: true)
        sats = Dictionary(uniqueKeysWithValues: catalog.satellites.map { ($0.id, $0) })
    }

    static func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)!
    }

    /// Pairs each expected time with the nearest of ours; returns the worst gap.
    func match(_ expected: [String], _ ours: [Date], _ label: String, tolerance: Double) -> Double {
        XCTAssertEqual(expected.count, ours.count, "count " + label)
        var worst = 0.0
        for e in expected.map(Self.date) {
            let gap = ours.map { abs($0.timeIntervalSince(e)) }.min() ?? .infinity
            worst = max(worst, gap)
            XCTAssertLessThan(gap, tolerance, label + " at \(e)")
        }
        return worst
    }

    func testBodiesMatchSkyfield() throws {
        var worstCross = (0.0, ""), worstPeakT = (0.0, ""), worstPeakA = (0.0, "")
        for d in fixture.bodies {
            let body = try XCTUnwrap(Body(rawValue: d.body))
            let obs = Observer(latitude: d.lat, longitude: d.lon, height: d.height)
            let ev = SkyFrame.events(of: body, observer: obs, from: Self.date(d.start), to: Self.date(d.end))
            let label = "\(d.body) @ \(d.place) \(d.start.prefix(10))"
            let c = max(match(d.rises, ev.rises.map(\.date), "rise " + label, tolerance: Self.bodyCrossing),
                        match(d.sets, ev.sets.map(\.date), "set " + label, tolerance: Self.bodyCrossing))
            if c > worstCross.0 { worstCross = (c, label) }
            // a maximum right at the window's edge is a coin toss for either search (Uranus transits
            // twice on 2026-06-21 in Sydney, at 00:00 and 23:59); compare the ones inside
            let (lo, hi) = (Self.date(d.start).addingTimeInterval(600), Self.date(d.end).addingTimeInterval(-600))
            let inside = d.peaks.filter { (lo...hi).contains(Self.date($0.t)) }
            let pt = match(inside.map(\.t), ev.peaks.map(\.date).filter { (lo...hi).contains($0) },
                           "peak " + label, tolerance: Self.bodyPeakTime)
            if pt > worstPeakT.0 { worstPeakT = (pt, label) }
            for p in inside {
                guard let ours = ev.peaks.min(by: { abs($0.date.timeIntervalSince(Self.date(p.t))) <
                                                    abs($1.date.timeIntervalSince(Self.date(p.t))) }) else { continue }
                let da = abs(ours.horizontal.altitude - p.alt) * 60
                if da > worstPeakA.0 { worstPeakA = (da, label) }
                XCTAssertLessThan(da, Self.bodyPeakAlt, "peak altitude " + label)
            }
        }
        print(String(format: "almanac bodies: worst crossing %.1f s (%@), peak time %.1f s (%@), peak alt %.2f′ (%@)",
                     worstCross.0, worstCross.1, worstPeakT.0, worstPeakT.1, worstPeakA.0, worstPeakA.1))
    }

    func testSatellitePassesMatchSkyfield() throws {
        let obs = Observer(latitude: fixture.place.lat, longitude: fixture.place.lon, height: fixture.place.height)
        var worstCross = (0.0, ""), worstPeakT = (0.0, ""), worstPeakA = (0.0, ""), total = 0
        for d in fixture.satellites {
            let sat = try XCTUnwrap(sats[d.id])
            let ours = SatelliteFrame.passes(of: [sat], observer: obs, from: Self.date(d.start), to: Self.date(d.end))[d.id] ?? []
            XCTAssertEqual(ours.count, d.passes.count, "pass count \(sat.name)")
            for p in d.passes {
                total += 1
                let rise = Self.date(p.rise)
                guard let o = ours.min(by: { abs($0.rise.date.timeIntervalSince(rise)) < abs($1.rise.date.timeIntervalSince(rise)) }) else {
                    XCTFail("no pass for \(sat.name) rising \(p.rise)"); continue
                }
                let label = "\(sat.name) \(p.rise)"
                let c = max(abs(o.rise.date.timeIntervalSince(rise)), abs(o.set.date.timeIntervalSince(Self.date(p.set))))
                if c > worstCross.0 { worstCross = (c, label) }
                XCTAssertLessThan(c, Self.satCrossing, "crossing " + label)
                // Skyfield can report several culminations on a long deep-space pass; ours is the highest
                guard let top = p.peaks.max(by: { $0.alt < $1.alt }) else { continue }
                let dt = abs(o.peak.date.timeIntervalSince(Self.date(top.t)))
                let da = abs(o.peak.horizontal.altitude - top.alt) * 60
                if dt > worstPeakT.0 { worstPeakT = (dt, label) }
                if da > worstPeakA.0 { worstPeakA = (da, label) }
                XCTAssertLessThan(dt, Self.satPeakTime, "peak time " + label)
                XCTAssertLessThan(da, Self.satPeakAlt, "peak altitude " + label)
            }
        }
        print(String(format: "almanac satellites: %d passes; worst crossing %.2f s (%@), peak time %.2f s (%@), peak alt %.3f′ (%@)",
                     total, worstCross.0, worstCross.1, worstPeakT.0, worstPeakT.1, worstPeakA.0, worstPeakA.1))
    }
}
