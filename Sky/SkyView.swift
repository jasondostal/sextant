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
    var h = 1.2
    h += 0.9 * sin(az * 2 + 0.7) + 0.6 * sin(az * 5 + 2.1) + 0.35 * sin(az * 11 + 0.4)
    h += 0.18 * sin(az * 37 + 1.3) + 0.12 * sin(az * 71 + 4.0) + 0.08 * sin(az * 143)
    return max(h, 0.4)
}

struct SkyObject {
    enum Kind { case star, planet, moon, sun }
    let name: String
    let kind: Kind
    let magnitude: Double
    let horizontal: Horizontal       // apparent
    let screen: CGPoint
}

private let starName = Color(red: 0.96, green: 0.84, blue: 0.42)
private let planetName = Color(red: 1.0, green: 0.93, blue: 0.84)
private let constellationName = Color(red: 0.55, green: 0.70, blue: 0.95).opacity(0.75)

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
                guard let p = proj.point(SIMD3<Float>(h)), aboveLand(Horizontal(vector: h)) else { continue }
                gc.draw(Text(c.name.uppercased()).font(.system(size: 10, weight: .medium)).tracking(2.2)
                    .foregroundStyle(constellationName), at: p)
            }

            // star and planet names, brightest first, skipping any that would collide
            var taken: [CGRect] = []
            let nameLimit = min(5.0, 2.4 + 2.0 * log2(max(1, 75 / cam.fov)))
            for o in visible where o.kind != .star || o.magnitude <= nameLimit {
                let color = o.kind == .star ? starName : planetName
                let text = Text(o.name).font(.system(size: o.kind == .star ? 12 : 13, weight: .medium))
                    .foregroundStyle(color)
                let resolved = gc.resolve(text)
                let s = resolved.measure(in: size)
                let rect = CGRect(x: o.screen.x + 9, y: o.screen.y - s.height / 2 - 1, width: s.width, height: s.height)
                if taken.contains(where: { $0.intersects(rect.insetBy(dx: -3, dy: -1)) }) { continue }
                taken.append(rect)
                gc.draw(resolved, in: rect)
            }

            // compass points, drawn on the land just under the hills
            for (i, n) in ["N", "NE", "E", "SE", "S", "SW", "W", "NW"].enumerated() {
                let h = Horizontal(altitude: -2.5, azimuth: Double(i) * 45)
                guard let p = proj.point(SIMD3<Float>(h.vector)) else { continue }
                gc.draw(Text(n).font(.system(size: i % 2 == 0 ? 15 : 11, weight: .semibold))
                    .foregroundStyle(i == 0 ? Color(red: 1, green: 0.45, blue: 0.4) : .white.opacity(0.7)), at: p)
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

    /// Named things in view and above the land, brightest first.
    private func visibleObjects(frame: SkyFrame, proj: Projector) -> [SkyObject] {
        var out: [SkyObject] = []
        for b in model.bodies(at: date) {
            let h = SIMD3<Float>(b.geometric.vector)
            guard aboveLand(b.apparent), let p = proj.point(refractHorizon(h)) else { continue }
            let kind: SkyObject.Kind = b.body == .sun ? .sun : b.body == .moon ? .moon : .planet
            out.append(SkyObject(name: b.body.rawValue, kind: kind, magnitude: b.magnitude,
                                 horizontal: b.apparent, screen: p))
        }
        let cat = model.sky.catalog
        for (i, name) in cat.names {
            let s = cat.stars[i]
            let geo = frame.horizontal(star: SIMD3<Double>(s.direction))
            let app = Horizontal(vector: SIMD3<Double>(refractHorizon(SIMD3<Float>(geo.vector))))
            guard aboveLand(app), let p = proj.point(SIMD3<Float>(app.vector)) else { continue }
            out.append(SkyObject(name: name, kind: .star, magnitude: Double(s.magnitude), horizontal: app, screen: p))
        }
        return out.sorted { $0.magnitude < $1.magnitude }
    }

    private func drawPill(_ gc: GraphicsContext, for o: SkyObject, size: CGSize) {
        let kind = switch o.kind {
        case .star: "Star"
        case .planet: "Planet"
        case .moon: "Moon"
        case .sun: "Sun"
        }
        let detail = String(format: "%@ · mag %.1f · %.0f° up, %@", kind, o.magnitude, o.horizontal.altitude,
                            compassPoint(o.horizontal.azimuth))
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
                Text(String(format: "%.0f° FOV", model.camera.fov)).foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
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
