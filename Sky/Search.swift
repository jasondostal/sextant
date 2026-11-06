import simd
import SkyCore
import SwiftUI

/// Something you can search for and fly to. Positions are resolved fresh each
/// frame, so a selected satellite or planet stays under the crosshair.
enum Target: Hashable {
    case star(Int)
    case body(Body)
    case constellation(Int)
    case satellite(Int)
    case deepSky(Int)
    case comet(String)          // MPC designation
    case shower(String)         // IMO code
}

struct Resolved {
    let name: String
    let kind: SkyObject.Kind?            // nil for a constellation
    /// Apparent direction (refracted), as drawn.
    let horizontal: Horizontal
    let magnitude: Double?
    let rangeKm: Double?
    let detail: String
}

extension SkyModel {
    func resolve(_ t: Target, at date: Date) -> Resolved? {
        func apparent(_ v: SIMD3<Double>) -> Horizontal {
            Horizontal(vector: SIMD3<Double>(refractHorizon(SIMD3<Float>(v))))
        }
        switch t {
        case .star(let i):
            let s = sky.catalog.stars[i]
            let h = apparent(frame(at: date).horizontal(star: SIMD3<Double>(s.direction)).vector)
            return Resolved(name: sky.catalog.names[i] ?? "Star", kind: .star, horizontal: h,
                            magnitude: Double(s.magnitude), rangeKm: nil, detail: "Star")
        case .body(let b):
            guard let p = bodies(at: date).first(where: { $0.body == b }) else { return nil }
            let kind: SkyObject.Kind = b == .sun ? .sun : b == .moon ? .moon : .planet
            return Resolved(name: b.rawValue, kind: kind, horizontal: p.apparent, magnitude: p.magnitude,
                            rangeKm: nil, detail: b == .sun || b == .moon ? b.rawValue : "Planet")
        case .constellation(let i):
            let c = sky.constellations[i]
            let h = Horizontal(vector: frame(at: date).eqjToHor * SIMD3<Double>(c.direction))
            return Resolved(name: c.name, kind: nil, horizontal: h, magnitude: nil, rangeKm: nil, detail: "Constellation")
        case .deepSky(let i):
            let d = DeepSkyObject.all[i]
            return Resolved(name: d.name, kind: .deepSky, horizontal: apparent(frame(at: date).horizontal(star: d.direction).vector),
                            magnitude: d.magnitude, rangeKm: nil, detail: d.kind + " · " + d.designation)
        case .comet(let id):
            guard let c = comets.first(where: { $0.id == id }) else { return nil }
            let p = frame(at: date).position(of: c)
            // the MPC's brightness law runs off to magnitude 30+ far from the Sun: just say faint
            let faint = p.magnitude > 15
            return Resolved(name: cometLabel(c), kind: .comet, horizontal: p.apparent, magnitude: faint ? nil : p.magnitude,
                            rangeKm: nil, detail: (c.id.contains("/") ? "Comet · " + c.id : "Comet") + (faint ? " · too faint to see now" : ""))
        case .shower(let code):
            guard let s = MeteorShower.all.first(where: { $0.code == code }) else { return nil }
            let r = s.radiant(at: date)
            return Resolved(name: s.name, kind: .shower,
                            horizontal: apparent(frame(at: date).horizontal(raHours: r.raHours, decDegrees: r.decDegrees).vector),
                            magnitude: nil, rangeKm: nil, detail: "Meteor shower · " + showerStatus(s, at: date))
        case .satellite(let id):
            guard let s = satellites.satellite(id: id),
                  let p = SatelliteFrame(date: date, observer: observer).position(of: s) else { return nil }
            var lit = p.horizontal.altitude < 0 ? "" : p.sunlit ? String(format: " · mag %.1f", p.magnitude) : " · in Earth's shadow"
            // which way it's going: where it'll be in a minute
            if p.horizontal.altitude > 0, let ahead = SatelliteFrame(date: date.addingTimeInterval(60), observer: observer).position(of: s) {
                lit += " · heading " + compassPoint(ahead.horizontal.azimuth)
            }
            return Resolved(name: Labels.displayName(s.name), kind: .satellite, horizontal: apparent(p.horizontal.vector),
                            magnitude: p.sunlit ? p.magnitude : nil, rangeKm: p.rangeKm, detail: "Satellite" + lit)
        }
    }

    /// Everything searchable whose name matches, best first: names that start
    /// with the query, then by kind (sky objects before the satellite crowd).
    func search(_ query: String, scope: SearchScope = .all, limit: Int = 60) -> [Target] {
        rankedSearch(query, scope: scope).prefix(limit).map(\.1)
    }

    /// The ranked hits behind `search`, for grouping by kind.
    func rankedSearch(_ query: String, scope: SearchScope = .all) -> [(Int, Target)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var hits: [(Int, Target)] = []
        func rank(_ name: String, _ base: Int, _ t: Target) {
            let n = name.lowercased()
            if n.hasPrefix(q) { hits.append((base, t)) }
            else if n.contains(" " + q) || n.contains("(" + q) { hits.append((base + 50, t)) }   // word start: "Andromeda Galaxy" for "gal"
            else if n.contains(q) { hits.append((base + 100, t)) }
        }
        let want = { (s: SearchScope) in scope == .all || scope == s }
        if want(.solarSystem) {
            for b in Body.allCases { rank(b.rawValue, 0, .body(b)) }
            for c in comets { rank(cometLabel(c) + " " + c.displayName + " comet", 12, .comet(c.id)) }
        }
        if want(.showers) { for s in MeteorShower.all { rank(s.name + " meteor shower " + s.code, 12, .shower(s.code)) } }
        if want(.constellations) { for (i, c) in sky.constellations.enumerated() { rank(c.name, 10, .constellation(i)) } }
        if want(.deepSky) { for (i, d) in DeepSkyObject.all.enumerated() { rank(d.name + " " + d.designation, 15, .deepSky(i)) } }
        if want(.stars) { for (i, n) in sky.catalog.names.sorted(by: { $0.key < $1.key }) { rank(n, 20, .star(i)) } }
        if want(.satellites) {
            let numeric = q.allSatisfy(\.isNumber)
            for s in satellites.all {
                let shown = Labels.displayName(s.name)
                // "ISS" / "Tiangong" / "Hubble" rank with the planets; the crowd ranks last
                rank(shown == s.name ? s.name : shown + " " + s.name, shown == s.name ? 40 : 5, .satellite(s.id))
                if numeric, String(s.id) == q { hits.append((1, .satellite(s.id))) }
                if hits.count > 4000 { break }
            }
        }
        return hits.sorted { $0.0 < $1.0 }
    }

    /// Lit satellites up right now, brightest first: "what's that moving?"
    func overheadNow(limit: Int = 8) -> [Target] {
        let date = now
        guard let sun = bodies(at: date).first(where: { $0.body == .sun }), sun.geometric.altitude < -3,
              satellitesValid(at: date) else { return [] }
        return satellites.positions(at: date, observer: observer)
            .filter { $0.position.sunlit && $0.position.horizontal.altitude > 5 && $0.position.magnitude <= 5.5 }
            .sorted { $0.position.magnitude < $1.position.magnitude }
            .prefix(limit).map { .satellite($0.satellite.id) }
    }

    /// Before anything is typed: the solar system and the famous satellites,
    /// what's up first.
    func suggestions() -> [Target] {
        let date = now
        var t: [Target] = Body.allCases.filter { $0 != .sun || resolve(.body(.sun), at: date)!.horizontal.altitude > -18 }
            .map { .body($0) }
        t += [25544, 48274, 20580].filter { satellites.satellite(id: $0) != nil }.map { .satellite($0) }
        t += sky.catalog.names.keys.sorted().prefix(12).map { .star($0) }
        t += DeepSkyObject.all.indices.filter { DeepSkyObject.all[$0].magnitude < 4 }.map { .deepSky($0) }
        // near the peak of a good shower, and comets you could see in binoculars
        t += MeteorShower.active(on: date).filter { ($0.shower.zhr ?? 0) >= 10 && abs($0.daysFromPeak) <= 3 }.map { .shower($0.shower.code) }
        t += cometPositions(at: date).filter { $0.magnitude <= 9 }.map { .comet($0.comet.id) }
        return upFirst(t, date)
    }

    /// Browsing one kind with nothing typed: all of it worth showing, what's up first.
    func browse(_ scope: SearchScope) -> [Target] {
        let date = now
        switch scope {
        case .all:
            return suggestions()
        case .solarSystem:
            let comets: [Target] = cometPositions(at: date).sorted { $0.magnitude < $1.magnitude }.map { .comet($0.comet.id) }
            return upFirst(Body.allCases.map { .body($0) }, date) + comets
        case .showers:
            // what's on now (nearest the peak first), then the year ahead in order
            let active = MeteorShower.active(on: date).sorted { abs($0.daysFromPeak) < abs($1.daysFromPeak) }.map(\.shower)
            let coming = MeteorShower.all.filter { !active.contains($0) }
                .sorted { nextPeak($0, after: date) < nextPeak($1, after: date) }
            return (active + coming).map { .shower($0.code) }
        case .satellites:
            // what's lit overhead, the famous three, then the brightest of the rest
            var t = overheadNow(limit: 12)
            t += [25544, 48274, 20580].filter { satellites.satellite(id: $0) != nil }.map { .satellite($0) }
            t += satellites.all.filter { $0.standardMagnitude <= 3 }.sorted { $0.standardMagnitude < $1.standardMagnitude }
                .prefix(30).map { .satellite($0.id) }
            var seen = Set<Target>()
            return t.filter { seen.insert($0).inserted }
        case .stars:
            let cat = sky.catalog
            return upFirst(cat.names.keys.sorted { cat.stars[$0].magnitude < cat.stars[$1].magnitude }.prefix(80).map { .star($0) }, date)
        case .deepSky:
            return upFirst(DeepSkyObject.all.indices.sorted { DeepSkyObject.all[$0].magnitude < DeepSkyObject.all[$1].magnitude }
                .map { .deepSky($0) }, date)
        case .constellations:
            let f = frame(at: date)
            return sky.constellations.indices
                .map { ($0, Horizontal(vector: f.eqjToHor * SIMD3<Double>(sky.constellations[$0].direction)).altitude) }
                .sorted { $0.1 > $1.1 }
                .map { .constellation($0.0) }
        }
    }

    /// Up before down, otherwise in the order given.
    private func upFirst(_ t: [Target], _ date: Date) -> [Target] {
        let up = t.map { (resolve($0, at: date)?.horizontal.altitude ?? -90) > 0 }
        return zip(t, up).enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 : a.offset < b.offset
        }.map(\.element.0)
    }
}

/// One kind's hits in the All view, ranked by its best match.
struct SearchGroup {
    let scope: SearchScope
    let best: Int
    let targets: [Target]

    static func make(_ ranked: [(Int, Target)]) -> [SearchGroup] {
        var byScope: [SearchScope: [(Int, Target)]] = [:]
        for hit in ranked { byScope[SearchScope(hit.1), default: []].append(hit) }
        let groups: [SearchGroup] = byScope.map { key, hits in
            SearchGroup(scope: key, best: hits[0].0, targets: hits.map { $0.1 })
        }
        return groups.sorted { a, b in
            a.best != b.best ? a.best < b.best : a.scope.rawValue < b.scope.rawValue
        }
    }
}

/// How results are ordered (the menu beside the search field).
enum SearchSort: String, CaseIterable, Identifiable {
    case relevance = "Best match", brightest = "Brightest", highest = "Highest now", name = "A–Z"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .relevance: "text.magnifyingglass"
        case .brightest: "sun.max"
        case .highest: "arrow.up.to.line"
        case .name: "textformat"
        }
    }
}

/// The chips under the search field.
enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All", solarSystem = "Solar system", satellites = "Satellites", stars = "Stars"
    case deepSky = "Deep sky", constellations = "Constellations", showers = "Meteor showers"
    var id: String { rawValue }

    init(_ t: Target) {
        switch t {
        case .body: self = .solarSystem
        case .satellite: self = .satellites
        case .star: self = .stars
        case .deepSky: self = .deepSky
        case .constellation: self = .constellations
        case .comet: self = .solarSystem
        case .shower: self = .showers
        }
    }

    var heading: String { rawValue.uppercased() }
}

/// Opened by the magnifying glass, closed by its X (or by choosing a result).
struct SearchPanel: View {
    @Bindable var model: SkyModel
    @Binding var open: Bool
    @State private var scope: SearchScope = .all
    @FocusState private var focused: Bool
    @AppStorage("searchSort") private var sort: SearchSort = .relevance
    @AppStorage("searchUpOnly") private var upOnly = false
    @AppStorage("searchNakedEye") private var nakedEye = false

    private var arranging: Bool { sort != .relevance || upOnly || nakedEye }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                TextField("Stars, planets, constellations, satellites", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .foregroundStyle(.white)
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: {
                        Image(systemName: "delete.left").font(.system(size: 16)).foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                arrangeMenu
                Button { open = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)

            chips.padding(.bottom, arranging ? 4 : 8)
            if arranging { arrangeSummary.padding(.bottom, 6) }

            // re-run the search when satellite data arrives (it loads in the background)
            let _ = model.satelliteCount
            // and every second: what's overhead changes, and the first sweep lands after the panel opens
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let date = model.now
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        content(date)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: 560)
        .background(Color(red: 0.01, green: 0.02, blue: 0.14).opacity(0.94), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
        .padding(.horizontal, 16).padding(.vertical, 12)
        #if os(macOS)
        .padding(.top, 28)        // clear the title bar
        #endif
        .onAppear {
            if let s = UserDefaults.standard.string(forKey: "searchScope"), let sc = SearchScope(rawValue: s) { scope = sc }
            // coming back to results: don't throw the keyboard over them
            focused = model.searchQuery.isEmpty
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchScope.allCases) { s in
                    Button { scope = s } label: {
                        Text(s.rawValue).font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(scope == s ? Color(red: 0.35, green: 0.45, blue: 0.75).opacity(0.6)
                                                                   : Color.white.opacity(0.07)))
                            .foregroundStyle(.white.opacity(scope == s ? 1 : 0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Sort and filter, one button: the search field stays the only thing at the top.
    private var arrangeMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(SearchSort.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            Section("Show") {
                Toggle("Up now only", isOn: $upOnly)
                Toggle("Naked-eye only (mag 6 or brighter)", isOn: $nakedEye)
            }
        } label: {
            Image(systemName: arranging ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 21))
                .foregroundStyle(arranging ? Color(red: 0.55, green: 0.65, blue: 0.95) : .white.opacity(0.6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// What's on, and a way to turn it all off.
    private var arrangeSummary: some View {
        HStack(spacing: 6) {
            Text(([sort == .relevance ? nil : sort.rawValue.lowercased() + " first",
                   upOnly ? "up now" : nil, nakedEye ? "naked-eye" : nil] as [String?]).compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color(red: 0.55, green: 0.65, blue: 0.95))
            Button {
                sort = .relevance; upOnly = false; nakedEye = false
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 18)
    }

    /// The menu's choices applied to a list. Satellites can number thousands; only
    /// the best 300 matches are considered, which is all anyone scrolls.
    private func arrange(_ targets: [Target], _ date: Date) -> [Target] {
        guard arranging else { return targets }
        let rows = targets.prefix(300).compactMap { t in model.resolve(t, at: date).map { (t, $0) } }
            .filter { _, r in (!upOnly || r.horizontal.altitude > 0) && (!nakedEye || (r.magnitude ?? -99) <= 6) }
        let sorted: [(Target, Resolved)] = switch sort {
        case .relevance: rows
        case .brightest: rows.sorted { ($0.1.magnitude ?? 99) < ($1.1.magnitude ?? 99) }
        case .highest: rows.sorted { $0.1.horizontal.altitude > $1.1.horizontal.altitude }
        case .name: rows.sorted { $0.1.name.localizedStandardCompare($1.1.name) == .orderedAscending }
        }
        return sorted.map(\.0)
    }

    @ViewBuilder private func content(_ date: Date) -> some View {
        let q = model.searchQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty && scope == .all {
            let overhead = model.overheadNow()
            header("OVERHEAD NOW")
            if overhead.isEmpty {
                note("Nothing lit overhead. Satellites shine in the hours after dusk and before dawn, when the sky is dark but they're still in sunlight.")
            }
            results(overhead, date)
            if !model.recents.isEmpty {
                HStack {
                    header("RECENT")
                    Spacer()
                    Button("Clear") { model.clearRecents() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        .padding(.trailing, 18).padding(.bottom, 6)
                }
                .padding(.top, 8)
                results(model.recents, date)
            }
            header("UP TONIGHT").padding(.top, 8)
            results(arrange(model.suggestions().filter { !overhead.contains($0) && !model.recents.contains($0) }, date), date)
        } else if q.isEmpty {
            let list = arrange(model.browse(scope), date)
            if list.isEmpty { note("Nothing in \(scope.rawValue.lowercased()) matches the filters.") }
            results(list, date)
        } else if scope != .all {
            let hits = arrange(model.search(q, scope: scope, limit: arranging ? 300 : scope == .satellites ? 100 : 60), date)
            if hits.isEmpty { note("Nothing called \"\(q)\" in \(scope.rawValue.lowercased()).") }
            results(hits, date)
        } else {
            grouped(q, date)
        }
    }

    /// All kinds at once: a few of each, kinds in the order of their best match.
    @ViewBuilder private func grouped(_ q: String, _ date: Date) -> some View {
        let groups = SearchGroup.make(model.rankedSearch(q)).compactMap { g -> SearchGroup? in
            let t = arrange(g.targets, model.now)
            return t.isEmpty ? nil : SearchGroup(scope: g.scope, best: g.best, targets: arranging ? t : g.targets)
        }
        if groups.isEmpty { note("Nothing called \"\(q)\".") }
        ForEach(Array(groups.enumerated()), id: \.element.scope) { i, g in
            let shown = groups.count == 1 ? 60 : 4
            header(g.scope.heading).padding(.top, i == 0 ? 0 : 8)
            results(Array(g.targets.prefix(shown)), date)
            if g.targets.count > shown {
                Button { scope = g.scope } label: {
                    Text(g.targets.count > 4000 ? "More \(g.scope.rawValue.lowercased()) ›" : "All \(g.targets.count) \(g.scope.rawValue.lowercased()) ›")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.55, green: 0.65, blue: 0.95))
                        .padding(.horizontal, 18).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(1.5)
            .foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 18).padding(.bottom, 6)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 18).padding(.bottom, 10)
    }

    @ViewBuilder private func results(_ targets: [Target], _ date: Date) -> some View {
        ForEach(targets, id: \.self) { t in
            if let r = model.resolve(t, at: date) {
                Button {
                    model.addRecent(t)
                    model.select(t)
                    model.searchReturn = true
                    UserDefaults.standard.set(scope.rawValue, forKey: "searchScope")
                    open = false
                } label: { row(r, hint: model.hints.text(for: t, model: model)) }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ r: Resolved, hint: String?) -> some View {
        let up = r.horizontal.altitude > 0
        let color: Color = switch r.kind {
        case .satellite?: Color(red: 0.31, green: 0.80, blue: 0.81)
        case .planet?: Color(red: 0.90, green: 0.60, blue: 0.60)
        case .star?: Color(red: 0.93, green: 0.91, blue: 0.78)
        case .deepSky?: Color(red: 0.74, green: 0.66, blue: 0.95)
        case .comet?: cometColor
        case .shower?: showerColor
        default: .white
        }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 16, weight: .medium)).foregroundStyle(color)
                Text(r.detail + (r.magnitude.map { r.kind == .satellite ? "" : String(format: " · mag %.1f", $0) } ?? ""))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(up ? String(format: "%.0f° up, %@", r.horizontal.altitude, compassPoint(r.horizontal.azimuth))
                        : "below horizon")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(up ? .white.opacity(0.8) : .white.opacity(0.35))
                Text(hint ?? " ")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(hint == "visible now" ? 0.9 : 0.45))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// The magnifying glass, bottom left like Star Walk's.
struct SearchButton: View {
    @Binding var open: Bool

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(red: 0.05, green: 0.09, blue: 0.20).opacity(0.82)))
                .overlay(Circle().stroke(.white.opacity(0.18)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

/// Visible tonight, next to search.
struct TonightButton: View {
    @Binding var open: Bool

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "moon.stars")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(red: 0.05, green: 0.09, blue: 0.20).opacity(0.82)))
                .overlay(Circle().stroke(.white.opacity(0.18)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
