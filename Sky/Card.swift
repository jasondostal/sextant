import simd
import SkyCore
import SwiftUI

/// What tapping the pill opens: everything about the selected object. For a
/// satellite, the questions you have while it's crossing: how long until it
/// fades into Earth's shadow, where it sets, when it's back.
struct DetailCard: View {
    let model: SkyModel
    let target: Target
    @Binding var open: Bool
    /// The slow parts, worked out once per target and night: tonight's chart, or the next day's passes.
    @State private var tonight: TonightReport?
    @State private var passes: [SatellitePass] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { t in
            let now = model.date(at: t.date)
            VStack(alignment: .leading, spacing: 10) {
                if let r = model.resolve(target, at: now) {
                    header(r)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if case .satellite(let id) = target, let sat = model.satellites.satellite(id: id) {
                                satellite(sat, r, now)
                            } else {
                                sky(r, now)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: 560)
        .background(Color(red: 0.01, green: 0.02, blue: 0.14).opacity(0.95), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
        .task(id: "\(target)-\(TonightReport.nightOf(model.now).timeIntervalSince1970)-\(model.observer.latitude)") { await load() }
    }

    private func header(_ r: Resolved) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                Text(kindLine(r)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button { open = false } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }

    private func kindLine(_ r: Resolved) -> String {
        if case .satellite(let id) = target { return "Satellite · NORAD \(id)" }
        return r.detail
    }

    // MARK: satellites

    @ViewBuilder private func satellite(_ sat: Satellite, _ r: Resolved, _ now: Date) -> some View {
        let frame = SatelliteFrame(date: now, observer: model.observer)
        if let p = frame.position(of: sat) {
            let up = p.horizontal.altitude > 0
            rows([
                ("Where", up ? "\(Int(r.horizontal.altitude.rounded()))° up, \(compassPoint(r.horizontal.azimuth))" : "below the horizon"),
                ("Brightness", !up ? "—" : p.sunlit ? (frame.sunAltitude < -3 ? String(format: "mag %.1f", p.magnitude) : "sunlit, but the sky's too bright")
                    : "in Earth's shadow (invisible)"),
                ("Distance", String(format: "%.0f km", p.rangeKm)),
            ])
            if up { thisPass(sat, p, now) }
            passList(now)
        }
    }

    /// While it's up: when it goes dark and when it sets.
    @ViewBuilder private func thisPass(_ sat: Satellite, _ p: SatellitePosition, _ now: Date) -> some View {
        let obs = model.observer
        let (shadow, set) = ending(sat, sunlit: p.sunlit, after: now)
        if let s = shadow, let q = SatelliteFrame(date: s, observer: obs).position(of: sat) {
            highlight("Fades into Earth's shadow in \(countdown(s.timeIntervalSince(now))), \(Int(q.horizontal.altitude.rounded()))° up in the \(compassPoint(q.horizontal.azimuth))")
        } else if let s = set, let q = SatelliteFrame(date: s, observer: obs).position(of: sat) {
            highlight("Sets in \(countdown(s.timeIntervalSince(now))) in the \(compassPoint(q.horizontal.azimuth))")
        }
    }

    /// Walk forward in 5 s steps to the shadow edge or the horizon, whichever
    /// comes first, then bisect to the instant.
    private func ending(_ sat: Satellite, sunlit: Bool, after now: Date) -> (shadow: Date?, set: Date?) {
        let obs = model.observer
        func at(_ t: Date) -> SatellitePosition? { SatelliteFrame(date: t, observer: obs).position(of: sat) }
        var t = now, prev = now
        for _ in 0..<720 {
            t = t.addingTimeInterval(5)
            guard let q = at(t) else { return (nil, nil) }
            if q.horizontal.altitude <= 0 {
                return (nil, Almanac.bisect(prev, t, above: false) { at($0)?.horizontal.altitude ?? -1 })
            }
            if sunlit && !q.sunlit {
                return (Almanac.bisect(prev, t, above: false) { (at($0)?.sunlit ?? false) ? 1 : -1 }, nil)
            }
            prev = t
        }
        return (nil, nil)
    }

    @ViewBuilder private func passList(_ now: Date) -> some View {
        let coming = passes.filter { ($0.visibleTo ?? $0.set).date > now && $0.isVisible }.prefix(6)
        Text(coming.isEmpty ? "NO VISIBLE PASSES IN THE NEXT DAY" : "VISIBLE PASSES")
            .font(.system(size: 11, weight: .semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.45))
            .padding(.top, 4)
        ForEach(Array(coming.enumerated()), id: \.offset) { _, p in
            let from = p.visibleFrom ?? p.rise, to = p.visibleTo ?? p.set, top = p.visiblePeak ?? p.peak
            Button {
                model.show(target, at: top.date)
                open = false
            } label: {
                HStack(spacing: 10) {
                    Text(dayClock(top.date, now)).frame(width: 110, alignment: .leading)
                    Text("\(compassPoint(from.horizontal.azimuth)) → \(compassPoint(to.horizontal.azimuth))")
                        .frame(width: 92, alignment: .leading)
                    Text("\(Int(top.horizontal.altitude.rounded()))° up").frame(width: 56, alignment: .leading)
                    Text(String(format: "mag %.1f", p.brightest ?? 0))
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: everything else

    private func sky(_ r: Resolved, _ now: Date) -> some View {
        var list: [(String, String)] = [
            ("Where", r.horizontal.altitude > 0
                ? "\(Int(r.horizontal.altitude.rounded()))° up, \(compassPoint(r.horizontal.azimuth))"
                : "below the horizon, \(compassPoint(r.horizontal.azimuth))"),
        ]
        if let m = r.magnitude { list.append(("Magnitude", String(format: "%.1f", m))) }
        if case .body(let b) = target, let p = model.bodies(at: now).first(where: { $0.body == b }) {
            if b != .sun { list.append(("Lit", "\(Int((p.phase * 100).rounded()))%")) }
            list.append(("Distance", b == .moon ? String(format: "%.0f km", p.distanceAU * 149_597_870.7)
                                               : String(format: "%.2f AU (%.0f light-min)", p.distanceAU, p.distanceAU * 8.317)))
        }
        // J2000 coordinates, from the horizon direction back through the frame (aberration ignored)
        let eqj = simd_transpose(model.frame(at: now).eqjToHor) * r.horizontal.vector
        list.append(("RA / Dec", raDec(eqj)))
        return VStack(alignment: .leading, spacing: 10) {
            rows(list)
            if let rep = tonight, let it = rep.items.first {
                Text(it.verdict).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                TonightChart(report: rep, item: it, now: now).frame(height: 130)
                let ev = (it.events.rises.map { ("Rises", $0) } + it.events.peaks.map { ("Highest", $0) } +
                          it.events.sets.map { ("Sets", $0) }).sorted { $0.1.date < $1.1.date }
                rows(ev.map { ($0.0, "\(clock($0.1.date)) · " + ($0.0 == "Highest"
                        ? "\(Int($0.1.horizontal.altitude.rounded()))° up, \(compassPoint($0.1.horizontal.azimuth))"
                        : compassPoint($0.1.horizontal.azimuth))) })
                if let best = it.best {
                    Button {
                        model.show(target, at: best)
                        open = false
                    } label: {
                        Label("Show at \(clock(best))", systemImage: "scope").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color(red: 0.35, green: 0.45, blue: 0.75).opacity(0.5)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            } else if tonight != nil {
                Text("Not up after dark tonight.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: pieces

    private func rows(_ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, kv in
                HStack(alignment: .firstTextBaseline) {
                    Text(kv.0).foregroundStyle(.white.opacity(0.5)).frame(width: 92, alignment: .leading)
                    Text(kv.1).foregroundStyle(.white.opacity(0.9))
                }
                .font(.system(size: 13).monospacedDigit())
            }
        }
    }

    private func highlight(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(red: 0.31, green: 0.80, blue: 0.81))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.31, green: 0.80, blue: 0.81).opacity(0.12)))
    }

    private func countdown(_ s: TimeInterval) -> String {
        let t = max(0, Int(s.rounded()))
        return t < 60 ? "\(t) s" : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// "6:43 AM" today, "Fri 6:43 AM" otherwise.
    private func dayClock(_ d: Date, _ now: Date) -> String {
        if Calendar.current.isDate(d, inSameDayAs: now) { return clock(d) }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return f.string(from: d)
    }

    private func raDec(_ v: SIMD3<Double>) -> String {
        var ra = atan2(v.y, v.x) * 12 / .pi
        if ra < 0 { ra += 24 }
        let dec = asin(max(-1, min(1, v.z))) * 180 / .pi
        let (h, m) = (Int(ra), Int((ra - Double(Int(ra))) * 60))
        let ad = abs(dec)
        return String(format: "%dh %02dm / %@%d° %02d′", h, m, dec < 0 ? "−" : "+", Int(ad), Int((ad - Double(Int(ad))) * 60))
    }

    // MARK: background work

    private func load() async {
        let (obs, now, t) = (model.observer, model.now, target)
        if case .satellite(let id) = t {
            guard let sat = model.satellites.satellite(id: id) else { return }
            passes = await Task.detached(priority: .userInitiated) {
                SatelliteFrame.passes(of: [sat], observer: obs, from: now.addingTimeInterval(-900),
                                      to: now.addingTimeInterval(86400))[id] ?? []
            }.value
            return
        }
        guard let r = model.resolve(t, at: now) else { return }
        let sky = model.sky
        let name = r.name
        tonight = await Task.detached(priority: .userInitiated) { () -> TonightReport in
            let night = TonightReport.Night(day: TonightReport.nightOf(now), observer: obs)
            var position: (SkyFrame) -> Horizontal
            var horizon = Almanac.horizon(for: nil)
            switch t {
            case .body(let b):
                position = { $0.position(of: b).geometric }
                horizon = Almanac.horizon(for: b)
            case .star(let i):
                let d = SIMD3<Double>(sky.catalog.stars[i].direction)
                position = { $0.horizontal(star: d) }
            case .deepSky(let i):
                let d = DeepSkyObject.all[i].direction
                position = { $0.horizontal(star: d) }
            case .constellation(let i):
                let d = SIMD3<Double>(sky.constellations[i].direction)
                position = { Horizontal(vector: $0.eqjToHor * d) }
                horizon = 0
            case .satellite:
                return night.report([])
            }
            let curve = night.frames.map { position($0).altitude }
            let events = Almanac.events(from: night.start, to: night.end, horizon: horizon) {
                position(SkyFrame(date: $0, observer: obs))
            }
            let item = night.item(t, name, .star, curve: curve, events: events)
            return night.report(item.map { [$0] } ?? [])
        }.value
    }
}
