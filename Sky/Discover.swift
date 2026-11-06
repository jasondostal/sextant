import Foundation
import Observation
import simd
import SkyCore

// The pieces search, the detail card and Visible tonight share: where a target
// is at any instant, when it next rises or sets, and when it's next worth
// looking for after dark.

extension Target {
    /// A stable string for remembering it (recent searches).
    var key: String {
        switch self {
        case .star(let i): "star:\(i)"
        case .body(let b): "body:\(b.rawValue)"
        case .constellation(let i): "con:\(i)"
        case .satellite(let id): "sat:\(id)"
        case .deepSky(let i): "dso:\(i)"
        }
    }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "star": guard let i = Int(parts[1]) else { return nil }; self = .star(i)
        case "body": guard let b = Body(rawValue: parts[1]) else { return nil }; self = .body(b)
        case "con": guard let i = Int(parts[1]) else { return nil }; self = .constellation(i)
        case "sat": guard let i = Int(parts[1]) else { return nil }; self = .satellite(i)
        case "dso": guard let i = Int(parts[1]) else { return nil }; self = .deepSky(i)
        default: return nil
        }
    }
}

/// How to find something that isn't a satellite: its airless direction in any
/// frame, and the altitude that counts as rising (centre on the standard horizon).
struct Track: @unchecked Sendable {
    let position: (SkyFrame) -> Horizontal
    let horizon: Double

    /// Nil for satellites (they have passes, not rise and set) and bad indices.
    static func of(_ t: Target, sky: SkyData) -> Track? {
        switch t {
        case .body(let b):
            return Track(position: { $0.position(of: b).geometric }, horizon: Almanac.horizon(for: b))
        case .star(let i):
            guard sky.catalog.stars.indices.contains(i) else { return nil }
            let d = SIMD3<Double>(sky.catalog.stars[i].direction)
            return Track(position: { $0.horizontal(star: d) }, horizon: Almanac.horizon(for: nil))
        case .deepSky(let i):
            guard DeepSkyObject.all.indices.contains(i) else { return nil }
            let d = DeepSkyObject.all[i].direction
            return Track(position: { $0.horizontal(star: d) }, horizon: Almanac.horizon(for: nil))
        case .constellation(let i):
            guard sky.constellations.indices.contains(i) else { return nil }
            let d = SIMD3<Double>(sky.constellations[i].direction)
            return Track(position: { Horizontal(vector: $0.eqjToHor * d) }, horizon: 0)
        case .satellite:
            return nil
        }
    }
}

/// For "next" times: just the clock within 18 hours (tonight's 2 AM is obviously tonight), else `dayClock`.
func soonClock(_ d: Date, _ now: Date) -> String {
    d.timeIntervalSince(now) < 18 * 3600 ? clock(d) : dayClock(d, now)
}

/// "6:43 AM" on the same day as `now`, "Fri 6:43 AM" within the week, "Mar 3" beyond.
func dayClock(_ d: Date, _ now: Date) -> String {
    if Calendar.current.isDate(d, inSameDayAs: now) { return clock(d) }
    let f = abs(d.timeIntervalSince(now)) < 6 * 86400 ? DayFormat.weekday : DayFormat.date
    return f.string(from: d)
}

enum DayFormat {
    static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; return f }()
    static let date: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd"); return f }()
}

// MARK: rise / set hints for search rows

/// One short line per search row: "sets 2:14 AM", "rises Fri 6:02 PM", "pass 6:12 PM".
/// Worked out off the main thread, once, and kept until the event it names has
/// passed, the observer moves, or time travel jumps.
@Observable
final class HintCache {
    private(set) var texts: [Target: String] = [:]
    @ObservationIgnored private var meta: [Target: (computed: Date, until: Date, observer: Observer)] = [:]
    @ObservationIgnored private var pending: Set<Target> = []
    @ObservationIgnored private let queue = DispatchQueue(label: "sextant.hints", qos: .userInitiated)

    func text(for t: Target, model: SkyModel) -> String? {
        let now = model.now, obs = model.observer
        let fresh = meta[t].map { m in
            now < m.until && now >= m.computed.addingTimeInterval(-60) && now.timeIntervalSince(m.computed) < 12 * 3600
                && abs(m.observer.latitude - obs.latitude) < 0.2 && abs(m.observer.longitude - obs.longitude) < 0.2
        } ?? false
        if !fresh, !pending.contains(t) {
            pending.insert(t)
            let sky = model.sky
            let sat: Satellite? = if case .satellite(let id) = t { model.satellites.satellite(id: id) } else { nil }
            let valid = model.satellitesValid(at: now)
            queue.async { [weak self] in
                let (text, until) = Self.compute(t, sky: sky, satellite: valid ? sat : nil, observer: obs, now: now)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pending.remove(t)
                    self.meta[t] = (now, until, obs)
                    if self.texts[t] != text { self.texts[t] = text }
                }
            }
        }
        return texts[t]
    }

    static func compute(_ t: Target, sky: SkyData, satellite: Satellite?, observer obs: Observer, now: Date) -> (String, Date) {
        if case .satellite = t {
            guard let sat = satellite else { return ("", now.addingTimeInterval(600)) }
            let passes = SatelliteFrame.passes(of: [sat], observer: obs, from: now.addingTimeInterval(-900),
                                               to: now.addingTimeInterval(36 * 3600))[sat.id] ?? []
            guard let p = passes.first(where: { $0.isVisible && ($0.visibleTo ?? $0.set).date > now }) else {
                return ("no visible pass soon", now.addingTimeInterval(3 * 3600))
            }
            let from = (p.visibleFrom ?? p.rise).date, to = (p.visibleTo ?? p.set).date
            if from <= now { return ("visible now", to) }
            return ("pass " + soonClock(from, now), from)
        }
        guard let tr = Track.of(t, sky: sky) else { return ("", now.addingTimeInterval(3600)) }
        let end = now.addingTimeInterval(26 * 3600)
        let ev = Almanac.events(from: now, to: end, horizon: tr.horizon) { tr.position(SkyFrame(date: $0, observer: obs)) }
        let up = tr.position(SkyFrame(date: now, observer: obs)).altitude > tr.horizon
        // stars and the like keep their declination: no rise in a day means never, from here
        var fixed = true
        if case .body = t { fixed = false }
        if up {
            if let s = ev.sets.first { return ("sets " + soonClock(s.date, now), s.date) }
            return (fixed ? "never sets" : "up all day", now.addingTimeInterval(6 * 3600))
        }
        if let r = ev.rises.first { return ("rises " + soonClock(r.date, now), r.date) }
        return (fixed ? "never rises here" : "doesn't rise today", now.addingTimeInterval(6 * 3600))
    }
}

// MARK: next chance after dark

struct NextChance {
    /// The best moment that night: highest with the Sun 6° or more down.
    let best: Date
    let altitude: Double
    let evening: Bool

    /// The first night, starting tomorrow, when it gets 10° up in a dark sky.
    /// Samples every 30 min from 5 PM to 7 AM local, for up to 400 nights.
    static func find(_ tr: Track, observer: Observer, after now: Date) -> NextChance? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        for day in 1...400 {
            guard let d = cal.date(byAdding: .day, value: day, to: today),
                  let evening = cal.date(bySettingHour: 17, minute: 0, second: 0, of: d) else { continue }
            var top: (Date, Double)?
            for k in 0...28 {
                let t = evening.addingTimeInterval(Double(k) * 1800)
                let f = SkyFrame(date: t, observer: observer)
                guard f.position(of: .sun).geometric.altitude < -6 else { continue }
                let alt = tr.position(f).altitude
                if alt > 10, alt > (top?.1 ?? -90) { top = (t, alt) }
            }
            if let (t, alt) = top {
                return NextChance(best: t, altitude: alt, evening: cal.isDate(t, inSameDayAs: d))
            }
        }
        return nil
    }
}

// MARK: recent searches

extension SkyModel {
    static let recentsKey = "recents"

    func addRecent(_ t: Target) {
        var keys = recents.map(\.key)
        keys.removeAll { $0 == t.key }
        keys.insert(t.key, at: 0)
        recents = keys.prefix(8).compactMap(Target.init(key:))
        UserDefaults.standard.set(recents.map(\.key), forKey: Self.recentsKey)
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    static func loadRecents() -> [Target] {
        (UserDefaults.standard.stringArray(forKey: recentsKey) ?? []).compactMap(Target.init(key:))
    }
}
