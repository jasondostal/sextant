import MetalKit
import simd
import SkyCore
import SwiftUI

struct SkyView: View {
    @State private var model = SkyModel()
    @State private var lastDrag: CGSize = .zero
    @State private var lastZoom: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                MetalSky(model: model)
                TimelineView(.animation) { timeline in
                    Labels(model: model, date: model.fixedDate ?? timeline.date)
                }
                .allowsHitTesting(false)
                VStack {
                    Readout(model: model)
                    Spacer()
                    if model.canPoint {
                        HStack {
                            Spacer()
                            PointButton(model: model)
                        }
                    }
                }
                .padding(.horizontal, 20)
                #if os(macOS)
                .padding(.top, 36)        // clear the title bar
                #else
                .padding(.top, 12)
                #endif
                .padding(.bottom, 18)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let d = CGSize(width: g.translation.width - lastDrag.width,
                                       height: g.translation.height - lastDrag.height)
                        lastDrag = g.translation
                        model.pan(dx: d.width, dy: d.height, perDegree: model.camera.perDegree(geo.size))
                    }
                    .onEnded { _ in lastDrag = .zero }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { g in
                            model.zoom(by: g.magnification / lastZoom)
                            lastZoom = g.magnification
                        }
                        .onEnded { _ in lastZoom = 1 })
            )
        }
        .ignoresSafeArea()
        .background(Color.black)
    }
}

/// Toggles point-at-the-sky mode; its label says which mode you're in.
struct PointButton: View {
    let model: SkyModel

    var body: some View {
        Button { model.setPointing(!model.pointing) } label: {
            Label(model.pointing ? "Pointing" : "Drag", systemImage: model.pointing ? "scope" : "hand.draw")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(Color(red: 0.05, green: 0.09, blue: 0.20).opacity(0.82)))
                .overlay(Capsule().stroke(model.pointing ? Color.cyan.opacity(0.7) : .white.opacity(0.18)))
                .foregroundStyle(model.pointing ? Color.cyan : .white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Metal view

#if os(iOS)
typealias ViewRepresentable = UIViewRepresentable
#else
typealias ViewRepresentable = NSViewRepresentable
#endif

struct MetalSky: ViewRepresentable {
    let model: SkyModel

    final class Coordinator { var renderer: Renderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    private func make(_ context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 60
        let r = Renderer(view: v, model: model)
        context.coordinator.renderer = r
        v.delegate = r
        return v
    }

    #if os(iOS)
    func makeUIView(context: Context) -> MTKView { make(context) }
    func updateUIView(_ view: MTKView, context: Context) {}
    #else
    func makeNSView(context: Context) -> MTKView { make(context) }
    func updateNSView(_ view: MTKView, context: Context) {}
    #endif
}

// MARK: - Labels, crosshair and the pill

/// Same hills as `terrainHeight` in Shaders.metal, so labels hide behind the land.
func terrainHeight(azimuthRadians az: Double) -> Double {
    var h = 0.75
    h += 0.45 * sin(az * 2 + 0.7) + 0.3 * sin(az * 5 + 2.1) + 0.2 * sin(az * 11 + 0.4)
    h += 0.12 * sin(az * 37 + 1.3) + 0.08 * sin(az * 71 + 4.0) + 0.05 * sin(az * 143)
    return max(h, 0.25)
}

struct SkyObject {
    enum Kind { case star, planet, moon, sun, satellite }
    let name: String
    let kind: Kind
    let magnitude: Double
    let horizontal: Horizontal       // apparent
    let screen: CGPoint
    /// Set, or behind the ridge: still drawn, through the lake, dimmed.
    let hidden: Bool
    var rangeKm: Double? = nil
}

// Star Walk 2's label colours, measured from Jason's screenshots.
private let starName = Color(red: 0.80, green: 0.79, blue: 0.67)
private let brightStarName = Color(red: 1.0, green: 1.0, blue: 0.80)
private let planetName = Color(red: 0.75, green: 0.44, blue: 0.45)
private let sunName = Color(red: 0.82, green: 0.82, blue: 0.32)
private let moonName = Color(red: 0.85, green: 0.86, blue: 0.88)
private let constellationName = Color(red: 0.72, green: 0.74, blue: 0.80)
private let satelliteName = Color(red: 0.31, green: 0.80, blue: 0.81)

struct Labels: View {
    let model: SkyModel
    let date: Date

    var body: some View {
        Canvas { gc, size in
            let cam = model.camera
            let proj = Projector(camera: cam, size: size)
            let frame = model.frame(at: date)
            let visible = visibleObjects(frame: frame, proj: proj)

            // constellation names: only the major ones when zoomed out
            let maxRank = cam.fov > 70 ? 1 : cam.fov > 35 ? 2 : 3
            for c in model.sky.constellations where c.rank <= maxRank {
                let h = frame.eqjToHor * SIMD3<Double>(c.direction)
                guard let p = proj.point(SIMD3<Float>(h)) else { continue }
                let dim = (c.rank == 1 ? 0.85 : 0.6) * (aboveLand(Horizontal(vector: h)) ? 1 : 0.35)
                gc.draw(Text(c.name.uppercased()).font(.system(size: 15, weight: .regular)).tracking(0.6)
                    .foregroundStyle(constellationName.opacity(dim)), at: p)
            }

            // star and planet names, brightest first, skipping any that would collide
            var taken: [CGRect] = []
            let nameLimit = min(5.0, 2.4 + 2.0 * log2(max(1, 75 / cam.fov)))
            let satNameLimit = min(6.5, 5.0 + 2.0 * log2(max(1, 75 / cam.fov)))
            for o in visible where (o.kind != .star || o.magnitude <= nameLimit)
                && (o.kind != .satellite || o.magnitude <= satNameLimit) {
                let color = switch o.kind {
                case .star: o.magnitude < 1 ? brightStarName : starName
                case .planet: planetName
                case .sun: sunName
                case .moon: moonName
                case .satellite: satelliteName
                }
                let text = Text(o.name).font(.system(size: 15, weight: .regular))
                    .foregroundStyle(color.opacity(o.hidden ? 0.45 : 1))
                let resolved = gc.resolve(text)
                let s = resolved.measure(in: size)
                // centred under the object, as Star Walk does
                let below: CGFloat = o.kind == .sun || o.kind == .moon ? 22 : 10
                let rect = CGRect(x: o.screen.x - s.width / 2, y: o.screen.y + below, width: s.width, height: s.height)
                if taken.contains(where: { $0.intersects(rect.insetBy(dx: -3, dy: -1)) }) { continue }
                taken.append(rect)
                gc.draw(resolved, in: rect)
            }

            // compass diamonds sitting on the horizon, Star Walk style
            for (i, n) in ["N", "E", "S", "W"].enumerated() {
                let h = Horizontal(altitude: -0.6, azimuth: Double(i) * 90)
                guard let p = proj.point(SIMD3<Float>(h.vector)) else { continue }
                var d = Path()
                d.move(to: CGPoint(x: p.x, y: p.y - 17)); d.addLine(to: CGPoint(x: p.x + 17, y: p.y))
                d.addLine(to: CGPoint(x: p.x, y: p.y + 17)); d.addLine(to: CGPoint(x: p.x - 17, y: p.y)); d.closeSubpath()
                gc.fill(d, with: .color(Color(red: 0.01, green: 0.02, blue: 0.15).opacity(0.6)))
                gc.stroke(d, with: .color(.white.opacity(0.8)), lineWidth: 1.2)
                gc.draw(Text(n).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9)), at: p)
            }

            // crosshair
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            gc.stroke(Path(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)),
                      with: .color(.white.opacity(0.55)), lineWidth: 1.2)

            if let hit = visible.min(by: { dist($0.screen, c) < dist($1.screen, c) }),
               dist(hit.screen, c) < min(size.width, size.height) * 0.07 {
                drawPill(gc, for: hit, size: size)
            }
        }
    }

    private func aboveLand(_ h: Horizontal) -> Bool {
        h.altitude > terrainHeight(azimuthRadians: h.azimuth * .pi / 180)
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Named things in view, brightest first.
    private func visibleObjects(frame: SkyFrame, proj: Projector) -> [SkyObject] {
        var out: [SkyObject] = []
        for b in model.bodies(at: date) {
            let h = SIMD3<Float>(b.geometric.vector)
            guard let p = proj.point(refractHorizon(h)) else { continue }
            let kind: SkyObject.Kind = b.body == .sun ? .sun : b.body == .moon ? .moon : .planet
            out.append(SkyObject(name: b.body.rawValue, kind: kind, magnitude: b.magnitude,
                                 horizontal: b.apparent, screen: p, hidden: !aboveLand(b.apparent)))
        }
        let cat = model.sky.catalog
        for (i, name) in cat.names {
            let s = cat.stars[i]
            let geo = frame.horizontal(star: SIMD3<Double>(s.direction))
            let app = Horizontal(vector: SIMD3<Double>(refractHorizon(SIMD3<Float>(geo.vector))))
            guard let p = proj.point(SIMD3<Float>(app.vector)) else { continue }
            out.append(SkyObject(name: name, kind: .star, magnitude: Double(s.magnitude), horizontal: app,
                                 screen: p, hidden: !aboveLand(app)))
        }
        for v in model.visibleSatellites(at: date) {
            let geo = SIMD3<Float>(v.position.horizontal.vector)
            let app = Horizontal(vector: SIMD3<Double>(refractHorizon(geo)))
            guard aboveLand(app), let p = proj.point(refractHorizon(geo)) else { continue }
            out.append(SkyObject(name: Self.displayName(v.satellite.name), kind: .satellite,
                                 magnitude: v.position.magnitude, horizontal: app, screen: p, hidden: false,
                                 rangeKm: v.position.rangeKm))
        }
        return out.sorted { $0.magnitude < $1.magnitude }
    }

    /// CelesTrak's names, made readable: "ISS (ZARYA)" → "ISS", "CSS (TIANHE)" → "Tiangong".
    static func displayName(_ n: String) -> String {
        switch n {
        case "ISS (ZARYA)": return "ISS"
        case "CSS (TIANHE)": return "Tiangong"
        case "HST": return "Hubble"
        default: return n
        }
    }

    private func drawPill(_ gc: GraphicsContext, for o: SkyObject, size: CGSize) {
        let kind = switch o.kind {
        case .star: "Star"
        case .planet: "Planet"
        case .moon: "Moon"
        case .sun: "Sun"
        case .satellite: "Satellite"
        }
        var detail = String(format: "%@ · mag %.1f · %.0f° up, %@", kind, o.magnitude, o.horizontal.altitude,
                            compassPoint(o.horizontal.azimuth))
        if let r = o.rangeKm { detail += String(format: " · %.0f km away", r) }
        let title = gc.resolve(Text(o.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
        let sub = gc.resolve(Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)))
        let ts = title.measure(in: size), ss = sub.measure(in: size)
        let w = max(ts.width, ss.width) + 36, h = ts.height + ss.height + 18
        let rect = CGRect(x: (size.width - w) / 2, y: size.height - h - 22, width: w, height: h)
        let pill = Path(roundedRect: rect, cornerRadius: h / 2)
        gc.fill(pill, with: .color(Color(red: 0.05, green: 0.09, blue: 0.20).opacity(0.82)))
        gc.stroke(pill, with: .color(.white.opacity(0.18)), lineWidth: 1)
        gc.draw(title, at: CGPoint(x: rect.midX, y: rect.minY + 9 + ts.height / 2))
        gc.draw(sub, at: CGPoint(x: rect.midX, y: rect.maxY - 9 - ss.height / 2))
    }
}

func compassPoint(_ az: Double) -> String {
    let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    return names[Int((az / 22.5).rounded()) % 16]
}

// MARK: - Readout

/// Where and when this sky is for, at the top where a glance lands. Amber
/// when it isn't your real position or the live time.
struct Readout: View {
    let model: SkyModel
    private static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { t in
            HStack(spacing: 14) {
                place
                Text(timeText(model.fixedDate ?? t.date))
                    .foregroundStyle(model.fixedDate == nil ? .white.opacity(0.75) : Self.amber)
                Spacer()
                satellites(t.date)
                Text(String(format: "%.0f° FOV", model.camera.fov)).foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }

    /// Orbit data age: amber after 3 days, when predictions start drifting.
    @ViewBuilder private func satellites(_ now: Date) -> some View {
        if let at = model.satellitesFetched {
            let hours = now.timeIntervalSince(at) / 3600
            Text("\(model.satelliteCount) sats · " + (hours < 1 ? "fresh" : hours < 48 ? "\(Int(hours)) h old" : "\(Int(hours / 24)) d old"))
                .foregroundStyle(hours > 72 ? Self.amber : .white.opacity(0.5))
        } else {
            Text("no satellite data").foregroundStyle(Self.amber)
        }
    }

    @ViewBuilder private var place: some View {
        switch model.location {
        case .fallback(let name):
            Text("\(name) · no GPS").foregroundStyle(Self.amber)
        case .gps(let at):
            let age = Date().timeIntervalSince(at)
            Text(String(format: "GPS %.2f°, %.2f° · %@", model.observer.latitude, model.observer.longitude,
                        age < 120 ? "now" : "\(Int(age / 60)) min ago"))
                .foregroundStyle(age > 6 * 3600 ? Self.amber : .white.opacity(0.75))
        }
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = model.fixedDate == nil ? "HH:mm" : "yyyy-MM-dd HH:mm zzz"
        return model.fixedDate == nil ? f.string(from: d) : "Frozen " + f.string(from: d)
    }
}
