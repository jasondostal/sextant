import simd
import SkyCore
import SwiftUI

/// "Visible tonight", after Star Walk's (Jason's favourite screen): what's worth
/// looking at between dusk and dawn, an altitude chart for the one you pick, and
/// for satellites the passes you can actually see rather than orbit wiggles.
struct TonightItem: Identifiable {
    enum Kind { case moon, planet, satellite, constellation, star }
    let id: Target
    let name: String
    let kind: Kind
    let verdict: String
    /// The tile's second line: when to look.
    let subtitle: String
    /// Altitude at each of the report's samples (empty for satellites).
    let curve: [Double]
    let events: Almanac.Events
    let passes: [SatellitePass]
    /// When to look: highest after dark, or the top of the best pass.
    let best: Date?
    /// Moon only: lit fraction, negative when waning.
    let phase: Double?
}

struct TonightReport {
    let day: Date
    let start: Date
    let step: TimeInterval
    let sunCurve: [Double]
    let sunset: Date?, sunrise: Date?
    /// Sun 6° down: dark enough for planets, bright stars and satellites.
    let dusk: Date?, dawn: Date?
    let items: [TonightItem]

    var end: Date { start.addingTimeInterval(step * Double(sunCurve.count - 1)) }
    func time(_ i: Int) -> Date { start.addingTimeInterval(step * Double(i)) }

    /// The night that's on at `date`: before noon still counts as last night.
    static func nightOf(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date.addingTimeInterval(-12 * 3600))
    }

    static func build(day: Date, observer: Observer, sky: SkyData, satellites: [Satellite]) -> TonightReport {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let step: TimeInterval = 600
        let n = Int(end.timeIntervalSince(start) / step)
        let frames = (0...n).map { SkyFrame(date: start.addingTimeInterval(Double($0) * step), observer: observer) }
        let sunCurve = frames.map { $0.position(of: .sun).geometric.altitude }
        let sunEvents = SkyFrame.events(of: .sun, observer: observer, from: start, to: end)
        let twilight = Almanac.events(from: start, to: end, horizon: -6) {
            SkyFrame(date: $0, observer: observer).position(of: .sun).geometric
        }
        let dark = sunCurve.indices.filter { sunCurve[$0] < -6 }
        let dusk = twilight.sets.first?.date, dawn = twilight.rises.first?.date

        func item(_ id: Target, _ name: String, _ kind: TonightItem.Kind, curve: [Double], events: Almanac.Events,
                  phase: Double? = nil, prefix: String = "") -> TonightItem? {
            guard let bestIdx = dark.max(by: { curve[$0] < curve[$1] }), curve[bestIdx] > 5 else { return nil }
            let best = start.addingTimeInterval(Double(bestIdx) * step)
            var v = prefix + verdict(curve: curve, dark: dark, events: events, dusk: dusk)
            v += " Highest after dark at \(clock(best)), \(Int(curve[bestIdx].rounded()))° up."
            return TonightItem(id: id, name: name, kind: kind, verdict: v, subtitle: "best \(clock(best))",
                               curve: curve, events: events, passes: [], best: best, phase: phase)
        }

        var items: [TonightItem] = []
        // the Moon and the naked-eye planets
        for b: Body in [.moon, .venus, .jupiter, .mars, .saturn, .mercury] {
            let pos = frames.map { $0.position(of: b) }
            let ev = SkyFrame.events(of: b, observer: observer, from: start, to: end)
            var prefix = ""
            var phase: Double?
            if b == .moon, let mid = dark.isEmpty ? nil : dark[dark.count / 2] {
                let waxing = pos[min(n, mid + 6)].phase > pos[mid].phase
                phase = waxing ? pos[mid].phase : -pos[mid].phase
                prefix = moonPhaseName(pos[mid].phase, waxing: waxing) + ", \(Int((pos[mid].phase * 100).rounded()))% lit. "
            }
            if let it = item(.body(b), b.rawValue, b == .moon ? .moon : .planet, curve: pos.map(\.geometric.altitude),
                             events: ev, phase: phase, prefix: prefix) { items.append(it) }
        }

        // satellites bright enough to notice, with a pass you can see
        let candidates = satellites.filter { $0.standardMagnitude <= 3.5 }
        let from = sunEvents.sets.first?.date ?? start, to = sunEvents.rises.first?.date ?? end
        let passes = SatelliteFrame.passes(of: candidates, observer: observer, from: from, to: to)
        var sats: [(Satellite, [SatellitePass], Double)] = []
        for s in candidates {
            let visible = (passes[s.id] ?? []).filter { ($0.brightest ?? 99) <= 4 }
            guard let b = visible.compactMap(\.brightest).min() else { continue }
            sats.append((s, visible, b))
        }
        let famous = [25544, 48274, 20580]
        sats.sort { a, b in
            let fa = famous.firstIndex(of: a.0.id) ?? 99, fb = famous.firstIndex(of: b.0.id) ?? 99
            return fa != fb ? fa < fb : a.2 < b.2
        }
        for (s, ps, _) in sats.prefix(10) {
            let top = ps.min { ($0.brightest ?? 99) < ($1.brightest ?? 99) }!
            let peak = top.visiblePeak ?? top.peak
            let path = "from \(compassPoint((top.visibleFrom ?? top.rise).horizontal.azimuth)) to \(compassPoint((top.visibleTo ?? top.set).horizontal.azimuth))"
            let v = (ps.count == 1 ? "One visible pass tonight" : "\(ps.count) visible passes tonight") +
                ". Best at \(clock(peak.date)): \(Int(peak.horizontal.altitude.rounded()))° up, " +
                String(format: "mag %.1f, ", top.brightest ?? 0) + path + "."
            items.append(TonightItem(id: .satellite(s.id), name: Labels.displayName(s.name), kind: .satellite, verdict: v,
                                     subtitle: clock(peak.date) + String(format: " · mag %.1f", top.brightest ?? 0),
                                     curve: [], events: Almanac.Events(), passes: ps, best: peak.date, phase: nil))
        }

        // the big constellations, highest in the middle of the night
        if !dark.isEmpty {
            let mid = dark[dark.count / 2]
            let cons = sky.constellations.enumerated()
                .filter { $0.element.rank == 1 }
                .map { ($0.offset, $0.element, Horizontal(vector: frames[mid].eqjToHor * SIMD3<Double>($0.element.direction)).altitude) }
                .filter { $0.2 > 30 }
                .sorted { $0.2 > $1.2 }
                .prefix(6)
            for (i, c, _) in cons {
                let curve = frames.map { Horizontal(vector: $0.eqjToHor * SIMD3<Double>(c.direction)).altitude }
                let ev = Almanac.events(from: start, to: end, horizon: 0) {
                    Horizontal(vector: SkyFrame(date: $0, observer: observer).eqjToHor * SIMD3<Double>(c.direction))
                }
                if let it = item(.constellation(i), c.name, .constellation, curve: curve, events: ev) { items.append(it) }
            }
        }

        // the brightest named stars that get well up
        let cat = sky.catalog
        let stars = cat.names.keys.filter { cat.stars[$0].magnitude < 1.6 }.sorted { cat.stars[$0].magnitude < cat.stars[$1].magnitude }
        var starItems: [TonightItem] = []
        for i in stars where starItems.count < 7 {
            let dir = SIMD3<Double>(cat.stars[i].direction)
            let curve = frames.map { $0.horizontal(star: dir).altitude }
            guard dark.contains(where: { curve[$0] > 15 }) else { continue }
            let ev = SkyFrame.events(ofStar: dir, observer: observer, from: start, to: end)
            if let it = item(.star(i), cat.names[i]!, .star, curve: curve, events: ev) { starItems.append(it) }
        }
        items += starItems

        return TonightReport(day: day, start: start, step: step, sunCurve: sunCurve,
                             sunset: sunEvents.sets.first?.date, sunrise: sunEvents.rises.first?.date,
                             dusk: dusk, dawn: dawn, items: items)
    }

    /// One sentence on when it's up after dark.
    static func verdict(curve: [Double], dark: [Int], events: Almanac.Events, dusk: Date?) -> String {
        let up = dark.filter { curve[$0] > 5 }
        guard let first = dark.first, let last = dark.last, !up.isEmpty else { return "Not up after dark tonight." }
        let atDusk = curve[first] > 5, atDawn = curve[last] > 5
        let after = dusk ?? .distantPast
        let set = events.sets.first { $0.date > after }.map { clock($0.date) }
        let rise = events.rises.first { $0.date > after }.map { clock($0.date) }
        if Double(up.count) > 0.95 * Double(dark.count) { return "Up all night." }
        switch (atDusk, atDawn) {
        case (true, false): return "Up in the evening" + (set.map { "; sets at \($0)." } ?? ".")
        case (false, true): return (rise.map { "Rises at \($0); " } ?? "") + "up until dawn."
        case (false, false): return "Up " + (rise.map { "from \($0) " } ?? "") + (set.map { "until \($0)." } ?? "for part of the night.")
        case (true, true): return "Up in the evening and again before dawn."
        }
    }

    static func moonPhaseName(_ f: Double, waxing: Bool) -> String {
        switch f {
        case ..<0.03: "New moon"
        case ..<0.47: waxing ? "Waxing crescent" : "Waning crescent"
        case ..<0.53: waxing ? "First quarter" : "Last quarter"
        case ..<0.97: waxing ? "Waxing gibbous" : "Waning gibbous"
        default: "Full moon"
        }
    }
}

func clock(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: d)
}

extension SkyModel {
    /// Jump the sky to `date` (time travel) and fly to the target.
    func show(_ t: Target, at date: Date?) {
        if let date {
            if fixedDate != nil { fixedDate = date } else { timeOffset = date.timeIntervalSince(Date()) }
            timeBarOpen = true
        }
        select(t)
    }
}

/// Opened by the moon-and-stars button, closed by its X.
struct TonightPanel: View {
    let model: SkyModel
    @Binding var open: Bool
    @State private var dayOffset = 0
    @State private var report: TonightReport?
    @State private var selected: Target?
    @State private var picked = false

    private var day: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: TonightReport.nightOf(model.now))!
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            VStack(spacing: 0) {
                header
                if let r = report, r.day == day {
                    let item = r.items.first { $0.id == selected } ?? r.items.first
                    if wide {
                        HStack(alignment: .top, spacing: 14) {
                            detail(r, item).frame(width: geo.size.width * 0.48)
                            ScrollView { grid(r, item) }
                        }
                    } else {
                        detail(r, item)
                        ScrollView { grid(r, item) }
                    }
                } else {
                    Spacer()
                    ProgressView().tint(.white)
                    Spacer()
                }
            }
            .padding(14)
        }
        .background(Color(red: 0.01, green: 0.02, blue: 0.14).opacity(0.96), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
        .padding(.horizontal, 12).padding(.vertical, 10)
        #if os(macOS)
        .padding(.top, 28)        // clear the title bar
        #endif
        .task(id: "\(day.timeIntervalSince1970)-\(model.satelliteCount)-\(model.observer.latitude)") {
            let (d, obs, sky, sats) = (day, model.observer, model.sky, model.satellites.all)
            let r = await Task.detached(priority: .userInitiated) {
                TonightReport.build(day: d, observer: obs, sky: sky, satellites: sats)
            }.value
            report = r
            // `-tonightPick ISS` (screenshots), once it shows up (satellites load later)
            if let pick = UserDefaults.standard.string(forKey: "tonightPick"), !picked,
               let it = r.items.first(where: { $0.name.hasPrefix(pick) }) {
                selected = it.id
                picked = true
            } else if selected == nil || !r.items.contains(where: { $0.id == selected }) {
                selected = r.items.first?.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { open = false } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            Text("Visible tonight").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            if dayOffset != 0 {
                Button("Tonight") { dayOffset = 0 }.buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.25))
            }
            Button { dayOffset -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Text(dayText).font(.system(size: 15, weight: .medium).monospacedDigit()).frame(minWidth: 96)
            Button { dayOffset += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.bottom, 10)
    }

    private var dayText: String {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f.string(from: day)
    }

    @ViewBuilder private func detail(_ r: TonightReport, _ item: TonightItem?) -> some View {
        if let item {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(color(item.kind))
                    Spacer()
                    showButton(item)
                }
                Text(item.verdict).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                TonightChart(report: r, item: item, now: model.now).frame(height: 150)
                if item.kind == .satellite { passList(item) }
            }
            .padding(.bottom, 12)
        } else {
            Text("Nothing up after dark.").foregroundStyle(.white.opacity(0.6)).padding(.vertical, 30)
        }
    }

    private func showButton(_ item: TonightItem) -> some View {
        let upNow = model.resolve(item.id, at: model.now).map { $0.horizontal.altitude > 0 } ?? false
        let dark = (model.bodies(at: model.now).first { $0.body == .sun }?.geometric.altitude ?? 0) < -6
        let jump = upNow && dark && item.kind != .satellite ? nil : item.best
        return Button {
            model.show(item.id, at: jump)
            open = false
        } label: {
            Label(jump.map { "Show at \(clock($0))" } ?? "Show now", systemImage: "scope")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Color(red: 0.35, green: 0.45, blue: 0.75).opacity(0.5)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func passList(_ item: TonightItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(item.passes.enumerated()), id: \.offset) { _, p in
                let from = p.visibleFrom ?? p.rise, to = p.visibleTo ?? p.set, top = p.visiblePeak ?? p.peak
                HStack(spacing: 10) {
                    Text(clock(top.date)).frame(width: 74, alignment: .leading)
                    Text("\(compassPoint(from.horizontal.azimuth)) → \(compassPoint(to.horizontal.azimuth))")
                        .frame(width: 92, alignment: .leading)
                    Text("\(Int(top.horizontal.altitude.rounded()))° up").frame(width: 56, alignment: .leading)
                    Text(String(format: "mag %.1f", p.brightest ?? 0))
                    Spacer()
                    Text("\(Int((to.date.timeIntervalSince(from.date) / 60).rounded())) min")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func grid(_ r: TonightReport, _ item: TonightItem?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
            ForEach(r.items) { it in
                Button { selected = it.id } label: {
                    VStack(spacing: 6) {
                        TileIcon(kind: it.kind, phase: it.phase).frame(width: 40, height: 40)
                        Text(it.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(color(it.kind))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(it.subtitle).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(it.id == item?.id ? 0.14 : 0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(it.id == item?.id ? 0.5 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func color(_ k: TonightItem.Kind) -> Color {
        switch k {
        case .moon: Color(red: 0.85, green: 0.86, blue: 0.88)
        case .planet: Color(red: 0.90, green: 0.60, blue: 0.60)
        case .satellite: Color(red: 0.31, green: 0.80, blue: 0.81)
        case .constellation: Color(red: 0.72, green: 0.74, blue: 0.80)
        case .star: Color(red: 0.93, green: 0.91, blue: 0.78)
        }
    }
}

/// Altitude over the night, on day / twilight / night bands like Star Walk's.
/// Satellites get a bar per pass instead of the orbit-by-orbit wiggle.
struct TonightChart: View {
    let report: TonightReport
    let item: TonightItem
    let now: Date

    var body: some View {
        Canvas { gc, size in
            let r = report
            let n = r.sunCurve.count
            let span = r.end.timeIntervalSince(r.start)
            func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(r.start) / span) * size.width }
            let top: CGFloat = 16, bottom: CGFloat = size.height - 16
            func y(_ alt: Double) -> CGFloat { top + (bottom - top) * CGFloat((90 - alt) / 180) }

            // sky bands, coloured by how far down the Sun is
            let colW = size.width / CGFloat(n - 1)
            for i in 0..<n {
                let s = r.sunCurve[i]
                let c: Color = s > 0 ? Color(red: 0.22, green: 0.36, blue: 0.66)
                    : s > -6 ? Color(red: 0.15, green: 0.23, blue: 0.47)
                    : s > -12 ? Color(red: 0.09, green: 0.13, blue: 0.31)
                    : s > -18 ? Color(red: 0.06, green: 0.08, blue: 0.21) : Color(red: 0.03, green: 0.04, blue: 0.13)
                gc.fill(Path(CGRect(x: CGFloat(i) * colW - colW / 2, y: top, width: colW + 0.5, height: bottom - top)),
                        with: .color(c))
            }
            // horizon, and the hour marks
            var h = Path()
            h.move(to: CGPoint(x: 0, y: y(0))); h.addLine(to: CGPoint(x: size.width, y: y(0)))
            gc.stroke(h, with: .color(Color(red: 0.45, green: 0.55, blue: 1.0).opacity(0.8)), lineWidth: 1)
            for hr in stride(from: 0, through: 24, by: 3) {
                let d = r.start.addingTimeInterval(Double(hr) * 3600)
                let f = DateFormatter()
                f.dateFormat = "ha"
                gc.draw(Text(f.string(from: d).lowercased()).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)),
                        at: CGPoint(x: min(max(x(d), 12), size.width - 12), y: size.height - 6))
            }
            gc.draw(Text("90°").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)), at: CGPoint(x: 12, y: top + 6))
            gc.draw(Text("0°").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)), at: CGPoint(x: 9, y: y(0) - 7))

            if item.kind == .satellite {
                for p in item.passes {
                    let px = x(p.peak.date)
                    let topY = y(p.peak.horizontal.altitude)
                    var bar = Path()
                    bar.move(to: CGPoint(x: px, y: y(0))); bar.addLine(to: CGPoint(x: px, y: topY))
                    let cyan = Color(red: 0.31, green: 0.80, blue: 0.81)
                    gc.stroke(bar, with: .color(cyan), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    gc.draw(Text(clock(p.peak.date)).font(.system(size: 9, weight: .medium)).foregroundStyle(cyan),
                            at: CGPoint(x: px, y: topY - 8))
                }
            } else {
                // above the horizon solid, below it dotted
                for above in [true, false] {
                    var path = Path(), on = false
                    for (i, a) in item.curve.enumerated() {
                        let p = CGPoint(x: CGFloat(i) * colW, y: y(a))
                        if (a > 0) == above {
                            if on { path.addLine(to: p) } else { path.move(to: p); on = true }
                        } else { on = false }
                    }
                    gc.stroke(path, with: .color(.white.opacity(above ? 0.95 : 0.35)),
                              style: StrokeStyle(lineWidth: above ? 2 : 1.2, dash: above ? [] : [2, 3]))
                }
                func mark(_ d: Date, _ label: String) {
                    var l = Path()
                    l.move(to: CGPoint(x: x(d), y: top)); l.addLine(to: CGPoint(x: x(d), y: bottom))
                    gc.stroke(l, with: .color(.white.opacity(0.25)), lineWidth: 0.8)
                    let t = Text("\(label) \(clock(d))").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    gc.draw(t, at: CGPoint(x: min(max(x(d), 40), size.width - 40), y: 6))
                }
                item.events.rises.forEach { mark($0.date, "Rise") }
                item.events.sets.forEach { mark($0.date, "Set") }
                if let b = item.best { mark(b, "Best") }
            }
            // now
            if now > r.start, now < r.end {
                var l = Path()
                l.move(to: CGPoint(x: x(now), y: top)); l.addLine(to: CGPoint(x: x(now), y: bottom))
                gc.stroke(l, with: .color(Color(red: 1.0, green: 0.72, blue: 0.25)), lineWidth: 1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Little drawn icons: Star Walk uses photos; these say the same thing in our style.
struct TileIcon: View {
    let kind: TonightItem.Kind
    let phase: Double?

    var body: some View {
        Canvas { gc, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 3
            switch kind {
            case .moon:
                let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                gc.fill(disc, with: .color(.white.opacity(0.12)))
                // lit part: the half facing the Sun (right when waxing, as seen from the
                // north), grown by the terminator ellipse when gibbous, cut by it when a crescent
                let f = abs(phase ?? 0.5), waning = (phase ?? 1) < 0
                var half = Path()
                half.addArc(center: c, radius: r, startAngle: .degrees(waning ? 90 : -90),
                            endAngle: .degrees(waning ? 270 : 90), clockwise: false)
                let w = r * CGFloat(abs(1 - 2 * f))
                let ellipse = Path(ellipseIn: CGRect(x: c.x - w, y: c.y - r, width: 2 * w, height: 2 * r))
                let moon = Color(red: 0.85, green: 0.86, blue: 0.88)
                if f >= 0.5 {
                    gc.fill(half, with: .color(moon))
                    gc.fill(ellipse, with: .color(moon))
                } else {
                    var g = gc
                    g.clip(to: Path(CGRect(x: waning ? c.x - r : c.x, y: c.y - r, width: r, height: 2 * r)))
                    var lit = half
                    lit.addPath(ellipse)
                    g.fill(lit, with: .color(moon), style: FillStyle(eoFill: true))
                }
            case .planet:
                gc.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.6, y: c.y - r * 0.6, width: r * 1.2, height: r * 1.2)),
                        with: .color(Color(red: 0.90, green: 0.60, blue: 0.60)))
            case .satellite:
                let cyan = Color(red: 0.31, green: 0.80, blue: 0.81)
                for k in 0..<3 {
                    var seg = Path()
                    let a = CGFloat(k) / 3, b = CGFloat(k + 1) / 3
                    seg.move(to: CGPoint(x: c.x - r + 2 * r * a * 0.8, y: c.y + r * 0.6 - 1.2 * r * a * 0.8))
                    seg.addLine(to: CGPoint(x: c.x - r + 2 * r * b * 0.8, y: c.y + r * 0.6 - 1.2 * r * b * 0.8))
                    gc.stroke(seg, with: .color(cyan.opacity(0.25 + 0.25 * Double(k))), lineWidth: 2)
                }
                let dot = CGPoint(x: c.x + r * 0.6, y: c.y - r * 0.36)
                gc.fill(Path(ellipseIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7)), with: .color(.white))
            case .constellation:
                let pts = [CGPoint(x: c.x - r * 0.8, y: c.y + r * 0.3), CGPoint(x: c.x - r * 0.2, y: c.y - r * 0.5),
                           CGPoint(x: c.x + r * 0.4, y: c.y + r * 0.1), CGPoint(x: c.x + r * 0.85, y: c.y - r * 0.6)]
                var p = Path()
                p.addLines(pts)
                gc.stroke(p, with: .color(.white.opacity(0.45)), lineWidth: 1)
                for q in pts { gc.fill(Path(ellipseIn: CGRect(x: q.x - 2, y: q.y - 2, width: 4, height: 4)), with: .color(.white)) }
            case .star:
                var s = Path()
                s.move(to: CGPoint(x: c.x, y: c.y - r)); s.addLine(to: CGPoint(x: c.x, y: c.y + r))
                s.move(to: CGPoint(x: c.x - r, y: c.y)); s.addLine(to: CGPoint(x: c.x + r, y: c.y))
                gc.stroke(s, with: .color(Color(red: 1.0, green: 1.0, blue: 0.85).opacity(0.7)), lineWidth: 1)
                gc.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.white))
            }
        }
    }
}
