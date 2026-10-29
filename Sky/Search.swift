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
        case .satellite(let id):
            guard let s = satellites.satellite(id: id),
                  let p = SatelliteFrame(date: date, observer: observer).position(of: s) else { return nil }
            let lit = p.horizontal.altitude < 0 ? "" : p.sunlit ? String(format: " · mag %.1f", p.magnitude) : " · in Earth's shadow"
            return Resolved(name: Labels.displayName(s.name), kind: .satellite, horizontal: apparent(p.horizontal.vector),
                            magnitude: p.sunlit ? p.magnitude : nil, rangeKm: p.rangeKm, detail: "Satellite" + lit)
        }
    }

    /// Everything searchable whose name matches, best first: names that start
    /// with the query, then by kind (sky objects before the satellite crowd).
    func search(_ query: String, limit: Int = 60) -> [Target] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return suggestions() }
        var hits: [(Int, Target)] = []
        func rank(_ name: String, _ base: Int, _ t: Target) {
            let n = name.lowercased()
            if n.hasPrefix(q) { hits.append((base, t)) } else if n.contains(q) { hits.append((base + 100, t)) }
        }
        for b in Body.allCases { rank(b.rawValue, 0, .body(b)) }
        for (i, c) in sky.constellations.enumerated() { rank(c.name, 10, .constellation(i)) }
        for (i, n) in sky.catalog.names.sorted(by: { $0.key < $1.key }) { rank(n, 20, .star(i)) }
        let numeric = q.allSatisfy(\.isNumber)
        for s in satellites.all {
            let shown = Labels.displayName(s.name)
            // "ISS" / "Tiangong" / "Hubble" rank with the planets; the crowd ranks last
            rank(shown == s.name ? s.name : shown + " " + s.name, shown == s.name ? 40 : 5, .satellite(s.id))
            if numeric, String(s.id) == q { hits.append((1, .satellite(s.id))) }
            if hits.count > 4000 { break }
        }
        return hits.sorted { $0.0 < $1.0 }.prefix(limit).map(\.1)
    }

    /// Before anything is typed: the solar system and the famous satellites,
    /// what's up first.
    func suggestions() -> [Target] {
        let date = now
        var t: [Target] = Body.allCases.filter { $0 != .sun || resolve(.body(.sun), at: date)!.horizontal.altitude > -18 }
            .map { .body($0) }
        t += [25544, 48274, 20580].filter { satellites.satellite(id: $0) != nil }.map { .satellite($0) }
        t += sky.catalog.names.keys.sorted().prefix(12).map { .star($0) }
        return t.sorted { (resolve($0, at: date)?.horizontal.altitude ?? -90 > 0 ? 0 : 1) <
                          (resolve($1, at: date)?.horizontal.altitude ?? -90 > 0 ? 0 : 1) }
    }
}

/// Opened by the magnifying glass, closed by its X (or by choosing a result).
struct SearchPanel: View {
    let model: SkyModel
    @Binding var open: Bool
    @State private var query = UserDefaults.standard.string(forKey: "search") ?? ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                TextField("Stars, planets, constellations, satellites", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .foregroundStyle(.white)
                Button { open = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .padding(14)

            let date = model.now
            // re-run the search when satellite data arrives (it loads in the background)
            let _ = model.satelliteCount
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        Text("UP TONIGHT").font(.system(size: 11, weight: .semibold)).tracking(1.5)
                            .foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 18).padding(.bottom, 6)
                    }
                    ForEach(model.search(query), id: \.self) { t in
                        if let r = model.resolve(t, at: date) {
                            Button {
                                model.select(t)
                                open = false
                            } label: { row(r) }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 560)
        .background(Color(red: 0.01, green: 0.02, blue: 0.14).opacity(0.94), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .onAppear { focused = true }
    }

    private func row(_ r: Resolved) -> some View {
        let up = r.horizontal.altitude > 0
        let color: Color = switch r.kind {
        case .satellite?: Color(red: 0.31, green: 0.80, blue: 0.81)
        case .planet?: Color(red: 0.90, green: 0.60, blue: 0.60)
        case .star?: Color(red: 0.93, green: 0.91, blue: 0.78)
        default: .white
        }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 16, weight: .medium)).foregroundStyle(color)
                Text(r.detail + (r.magnitude.map { r.kind == .satellite ? "" : String(format: " · mag %.1f", $0) } ?? ""))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Text(up ? String(format: "%.0f° up, %@", r.horizontal.altitude, compassPoint(r.horizontal.azimuth))
                    : "below horizon")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(up ? .white.opacity(0.8) : .white.opacity(0.35))
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
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
