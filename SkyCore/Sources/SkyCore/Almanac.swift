import Foundation
import simd

/// When things rise, set and reach their highest: the times behind "visible tonight".
/// Altitudes are airless (geometric) and topocentric, of the object's centre.
public enum Almanac {
    public struct Event: Sendable {
        public let date: Date
        public let horizontal: Horizontal
    }

    public struct Events: Sendable {
        public var rises: [Event] = []
        public var sets: [Event] = []
        /// Highest points (upper transits for stars and planets).
        public var peaks: [Event] = []
    }

    /// Where the centre is when the edge touches a flat horizon, refraction included:
    /// 34′ of refraction, plus 16′ of semi-diameter for the Sun and Moon.
    public static func horizon(for body: Body?) -> Double {
        body == .sun || body == .moon ? -0.8333 : -0.5667
    }

    /// Rises, sets and highest points between `start` and `end`. Sampled every
    /// `step` (nothing that matters here rises and sets within five minutes),
    /// crossings refined by bisection, maxima by golden-section search.
    public static func events(from start: Date, to end: Date, step: TimeInterval = 300, horizon: Double,
                              position: (Date) -> Horizontal) -> Events {
        var out = Events()
        let n = max(2, Int((end.timeIntervalSince(start) / step).rounded(.up)))
        let dt = end.timeIntervalSince(start) / Double(n)
        let times = (0...n).map { start.addingTimeInterval(Double($0) * dt) }
        let alts = times.map { position($0).altitude }

        for i in 1...n {
            let a = alts[i - 1] - horizon, b = alts[i] - horizon
            if (a <= 0) != (b <= 0) {
                let t = bisect(times[i - 1], times[i], above: b > 0) { position($0).altitude - horizon }
                let e = Event(date: t, horizontal: position(t))
                if b > 0 { out.rises.append(e) } else { out.sets.append(e) }
            }
        }
        // a maximum strictly inside the window: bracket it with the samples either side
        for i in 1..<n where alts[i] >= alts[i - 1] && alts[i] > alts[i + 1] {
            let t = goldenMax(times[i - 1], times[i + 1]) { position($0).altitude }
            out.peaks.append(Event(date: t, horizontal: position(t)))
        }
        return out
    }

    /// Bisect to 0.1 s for the instant `f` changes sign; `above` says which side is positive at `b`.
    static func bisect(_ a: Date, _ b: Date, above: Bool, _ f: (Date) -> Double) -> Date {
        var lo = a, hi = b
        while hi.timeIntervalSince(lo) > 0.1 {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            if (f(mid) > 0) == above { hi = mid } else { lo = mid }
        }
        return lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
    }

    static func goldenMax(_ a: Date, _ b: Date, _ f: (Date) -> Double) -> Date {
        let g = (sqrt(5.0) - 1) / 2
        var lo = a.timeIntervalSince1970, hi = b.timeIntervalSince1970
        var x1 = hi - g * (hi - lo), x2 = lo + g * (hi - lo)
        var f1 = f(Date(timeIntervalSince1970: x1)), f2 = f(Date(timeIntervalSince1970: x2))
        while hi - lo > 0.5 {
            if f1 < f2 {
                lo = x1; x1 = x2; f1 = f2
                x2 = lo + g * (hi - lo); f2 = f(Date(timeIntervalSince1970: x2))
            } else {
                hi = x2; x2 = x1; f2 = f1
                x1 = hi - g * (hi - lo); f1 = f(Date(timeIntervalSince1970: x1))
            }
        }
        return Date(timeIntervalSince1970: (lo + hi) / 2)
    }
}

extension SkyFrame {
    /// Rises, sets and highest points of a body over a window.
    public static func events(of body: Body, observer: Observer, from start: Date, to end: Date) -> Almanac.Events {
        Almanac.events(from: start, to: end, horizon: Almanac.horizon(for: body)) {
            SkyFrame(date: $0, observer: observer).position(of: body).geometric
        }
    }

    /// The same for a fixed star (J2000 direction, proper motion already applied).
    public static func events(ofStar direction: SIMD3<Double>, observer: Observer, from start: Date, to end: Date) -> Almanac.Events {
        Almanac.events(from: start, to: end, horizon: Almanac.horizon(for: nil)) {
            SkyFrame(date: $0, observer: observer).horizontal(star: direction)
        }
    }
}

/// One trip of a satellite across the sky, and the part of it you can see.
public struct SatellitePass: Sendable {
    public let rise: Almanac.Event
    public let peak: Almanac.Event
    public let set: Almanac.Event
    /// The stretch where it's sunlit and the sky is dark enough (Sun below −3°).
    public let visibleFrom: Almanac.Event?
    public let visibleTo: Almanac.Event?
    /// Brightest magnitude while visible.
    public let brightest: Double?
    /// Highest point while visible (equals `peak` unless it's in shadow at the top).
    public let visiblePeak: Almanac.Event?

    public var isVisible: Bool { visibleFrom != nil }
}

extension SatelliteFrame {
    /// The Sun's altitude at the observer, degrees (geocentric direction: parallax is 9″).
    public var sunAltitude: Double { asin(max(-1, min(1, simd_dot(sun, up)))) * 180 / .pi }

    /// Passes of each satellite between `start` and `end`, keyed by NORAD id.
    /// One shared 20 s grid of frames, so a thousand satellites over a night cost
    /// a few million SGP4 calls; crossings refined to 0.1 s, culminations to 0.5 s.
    public static func passes(of satellites: [Satellite], observer: Observer, from start: Date, to end: Date,
                              darkSun: Double = -3) -> [Int: [SatellitePass]] {
        let step: TimeInterval = 20
        let n = max(2, Int((end.timeIntervalSince(start) / step).rounded(.up)))
        let frames = (0...n).map { SatelliteFrame(date: start.addingTimeInterval(Double($0) * step), observer: observer) }
        var out: [Int: [SatellitePass]] = [:]
        for sat in satellites {
            func alt(_ t: Date) -> Double {
                SatelliteFrame(date: t, observer: observer).position(of: sat)?.horizontal.altitude ?? -90
            }
            func event(_ t: Date) -> Almanac.Event {
                let p = SatelliteFrame(date: t, observer: observer).position(of: sat)
                return Almanac.Event(date: t, horizontal: p?.horizontal ?? Horizontal(altitude: -90, azimuth: 0))
            }
            let alts = frames.map { $0.position(of: sat)?.horizontal.altitude ?? -90 }
            var list: [SatellitePass] = []
            var riseAt: Date?
            for i in 1...n {
                if alts[i - 1] <= 0, alts[i] > 0 {
                    riseAt = Almanac.bisect(frames[i - 1].date, frames[i].date, above: true, alt)
                } else if alts[i - 1] > 0, alts[i] <= 0, let r = riseAt {
                    let s = Almanac.bisect(frames[i - 1].date, frames[i].date, above: false, alt)
                    list.append(pass(sat, observer, rise: r, set: s, darkSun: darkSun, event: event, alt: alt))
                    riseAt = nil
                }
            }
            if !list.isEmpty { out[sat.id] = list }
        }
        return out
    }

    static func pass(_ sat: Satellite, _ observer: Observer, rise: Date, set: Date, darkSun: Double,
                     event: (Date) -> Almanac.Event, alt: (Date) -> Double) -> SatellitePass {
        // culmination: find the best 10 s sample, then refine around it
        let span = set.timeIntervalSince(rise)
        let k = max(2, Int(span / 10))
        var best = (0, -90.0)
        var visible: [(Date, SatellitePosition)] = []
        for j in 0...k {
            let t = rise.addingTimeInterval(span * Double(j) / Double(k))
            let f = SatelliteFrame(date: t, observer: observer)
            guard let p = f.position(of: sat) else { continue }
            if p.horizontal.altitude > best.1 { best = (j, p.horizontal.altitude) }
            if p.sunlit && f.sunAltitude < darkSun { visible.append((t, p)) }
        }
        let a = rise.addingTimeInterval(span * Double(max(0, best.0 - 1)) / Double(k))
        let b = rise.addingTimeInterval(span * Double(min(k, best.0 + 1)) / Double(k))
        let peak = event(Almanac.goldenMax(a, b, alt))
        let top = visible.max { $0.1.horizontal.altitude < $1.1.horizontal.altitude }
        return SatellitePass(
            rise: event(rise), peak: peak, set: event(set),
            visibleFrom: visible.first.map { event($0.0) }, visibleTo: visible.last.map { event($0.0) },
            brightest: visible.map(\.1.magnitude).min(),
            visiblePeak: top.map { Almanac.Event(date: $0.0, horizontal: $0.1.horizontal) })
    }
}
