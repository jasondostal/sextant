import MetalKit
import simd
import SkyCore
import SwiftUI

struct SkyView: View {
    @State private var model = SkyModel()
    @State private var lastDrag: CGSize = .zero
    @State private var lastZoom: CGFloat = 1
    // `-search jup` opens the panel with a query (screenshots)
    @State private var searching = UserDefaults.standard.string(forKey: "search") != nil

    var body: some View {
        ZStack {
            sky
            if searching {
                SearchPanel(model: model, open: $searching)
            }
        }
        .ignoresSafeArea(.container)
        .background(Color.black)
    }

    private var sky: some View {
        GeometryReader { geo in
            ZStack {
                MetalSky(model: model)
                TimelineView(.animation) { timeline in
                    Labels(model: model, date: model.date(at: timeline.date))
                }
                .allowsHitTesting(false)
                if model.timeBarOpen {
                    HStack {
                        Spacer()
                        TimeRuler(model: model).frame(height: geo.size.height * 0.5)
                    }
                    .padding(.trailing, 4)
                }
                VStack {
                    Readout(model: model)
                    if model.timeBarOpen { TimeBar(model: model).padding(.top, 6) }
                    Spacer()
                    HStack {
                        SearchButton(open: $searching)
                        if model.target != nil {
                            Button { model.clearTarget() } label: {
                                Label("Clear", systemImage: "scope").font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Capsule().fill(Color(red: 0.05, green: 0.09, blue: 0.20).opacity(0.82)))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        if model.canPoint { PointButton(model: model) }
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
                    .simultaneously(with: SpatialTapGesture()
                        .onEnded { tap in
                            // the nearest named thing within a fingertip
                            let proj = Projector(camera: model.camera, size: geo.size)
                            let hit = model.objects(at: model.now, proj: proj)
                                .filter { $0.target != nil }
                                .min { hypot($0.screen.x - tap.location.x, $0.screen.y - tap.location.y) <
                                       hypot($1.screen.x - tap.location.x, $1.screen.y - tap.location.y) }
                            if let h = hit, hypot(h.screen.x - tap.location.x, h.screen.y - tap.location.y) < 30 {
                                model.select(h.target!, fly: false)
                            }
                        })
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { g in
                            model.zoom(by: g.magnification / lastZoom)
                            lastZoom = g.magnification
                        }
                        .onEnded { _ in lastZoom = 1 })
            )
        }
        .ignoresSafeArea()
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
    enum Kind { case star, planet, moon, sun, satellite, deepSky }
    let name: String
    let kind: Kind
    let magnitude: Double
    let horizontal: Horizontal       // apparent
    let screen: CGPoint
    /// Set, or behind the ridge: still drawn, through the lake, dimmed.
    let hidden: Bool
    var rangeKm: Double? = nil
    /// Overrides the pill's kind line (search targets carry their own).
    var detail: String? = nil
    /// What tapping it selects.
    var target: Target? = nil
}

func aboveLand(_ h: Horizontal) -> Bool {
    h.altitude > terrainHeight(azimuthRadians: h.azimuth * .pi / 180)
}

extension SkyModel {
    /// Named things in view, brightest first: what gets labels, the pill, and taps.
    func objects(at date: Date, proj: Projector) -> [SkyObject] {
        let frame = frame(at: date)
        var out: [SkyObject] = []
        for b in bodies(at: date) {
            let h = SIMD3<Float>(b.geometric.vector)
            guard let p = proj.point(refractHorizon(h)) else { continue }
            let kind: SkyObject.Kind = b.body == .sun ? .sun : b.body == .moon ? .moon : .planet
            out.append(SkyObject(name: b.body.rawValue, kind: kind, magnitude: b.magnitude,
                                 horizontal: b.apparent, screen: p, hidden: !aboveLand(b.apparent), target: .body(b.body)))
        }
        let cat = sky.catalog
        for (i, name) in cat.names {
            let s = cat.stars[i]
            let geo = frame.horizontal(star: SIMD3<Double>(s.direction))
            let app = Horizontal(vector: SIMD3<Double>(refractHorizon(SIMD3<Float>(geo.vector))))
            guard let p = proj.point(SIMD3<Float>(app.vector)) else { continue }
            out.append(SkyObject(name: name, kind: .star, magnitude: Double(s.magnitude), horizontal: app,
                                 screen: p, hidden: !aboveLand(app), target: .star(i)))
        }
        for (i, d) in DeepSkyObject.all.enumerated() {
            let app = Horizontal(vector: SIMD3<Double>(refractHorizon(SIMD3<Float>(frame.horizontal(star: d.direction).vector))))
            guard let p = proj.point(SIMD3<Float>(app.vector)) else { continue }
            out.append(SkyObject(name: d.name, kind: .deepSky, magnitude: d.magnitude, horizontal: app, screen: p,
                                 hidden: !aboveLand(app), detail: d.kind + " · " + d.designation, target: .deepSky(i)))
        }
        for v in visibleSatellites(at: date) {
            let geo = SIMD3<Float>(v.position.horizontal.vector)
            let app = Horizontal(vector: SIMD3<Double>(refractHorizon(geo)))
            guard aboveLand(app), let p = proj.point(refractHorizon(geo)) else { continue }
            out.append(SkyObject(name: Labels.displayName(v.satellite.name), kind: .satellite,
                                 magnitude: v.position.magnitude, horizontal: app, screen: p, hidden: false,
                                 rangeKm: v.position.rangeKm, target: .satellite(v.satellite.id)))
        }
        return out.sorted { $0.magnitude < $1.magnitude }
    }
}

// Star Walk 2's label colours, measured from Jason's screenshots.
private let starName = Color(red: 0.80, green: 0.79, blue: 0.67)
private let brightStarName = Color(red: 1.0, green: 1.0, blue: 0.80)
private let planetName = Color(red: 0.75, green: 0.44, blue: 0.45)
private let sunName = Color(red: 0.82, green: 0.82, blue: 0.32)
private let moonName = Color(red: 0.85, green: 0.86, blue: 0.88)
private let constellationName = Color(red: 0.72, green: 0.74, blue: 0.80)
private let satelliteName = Color(red: 0.31, green: 0.80, blue: 0.81)
private let deepSkyName = Color(red: 0.74, green: 0.66, blue: 0.95)

struct Labels: View {
    let model: SkyModel
    let date: Date

    var body: some View {
        Canvas { gc, size in
            let cam = model.camera
            let proj = Projector(camera: cam, size: size)
            let frame = model.frame(at: date)
            let visible = model.objects(at: date, proj: proj)
            #if os(macOS)
            var topBand: CGFloat = 70          // title bar + readout
            #else
            var topBand: CGFloat = 40          // readout
            #endif
            if model.timeBarOpen { topBand += 48 }

            if case .satellite(let id)? = model.target { drawTrack(gc, satellite: id, proj: proj, size: size) }

            // constellation names: only the major ones when zoomed out
            let maxRank = cam.fov > 70 ? 1 : cam.fov > 35 ? 2 : 3
            for c in model.sky.constellations where c.rank <= maxRank {
                let h = frame.eqjToHor * SIMD3<Double>(c.direction)
                guard let p = proj.point(SIMD3<Float>(h)) else { continue }
                let dim = (c.rank == 1 ? 0.85 : 0.6) * (aboveLand(Horizontal(vector: h)) ? 1 : 0.35)
                guard p.y > topBand + 10 else { continue }
                gc.draw(Text(c.name.uppercased()).font(.system(size: 15, weight: .regular)).tracking(0.6)
                    .foregroundStyle(constellationName.opacity(dim)), at: p)
            }

            // star and planet names, brightest first, skipping any that would collide
            var taken: [CGRect] = []
            let nameLimit = min(5.0, 2.4 + 2.0 * log2(max(1, 75 / cam.fov)))
            let satNameLimit = min(6.5, 5.0 + 2.0 * log2(max(1, 75 / cam.fov)))
            for o in visible where (o.kind != .star || o.magnitude <= nameLimit)
                && (o.kind != .satellite || o.magnitude <= satNameLimit)
                && (o.kind != .deepSky || cam.fov < 100) {
                let color = switch o.kind {
                case .star: o.magnitude < 1 ? brightStarName : starName
                case .planet: planetName
                case .sun: sunName
                case .moon: moonName
                case .satellite: satelliteName
                case .deepSky: deepSkyName
                }
                if o.kind == .deepSky {
                    // a soft marker: these are smudges, not points
                    gc.stroke(Path(ellipseIn: CGRect(x: o.screen.x - 7, y: o.screen.y - 7, width: 14, height: 14)),
                              with: .color(deepSkyName.opacity(o.hidden ? 0.25 : 0.55)),
                              style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
                }
                let text = Text(o.name).font(.system(size: 15, weight: .regular))
                    .foregroundStyle(color.opacity(o.hidden ? 0.45 : 1))
                let resolved = gc.resolve(text)
                let s = resolved.measure(in: size)
                // centred under the object, as Star Walk does
                let below: CGFloat = o.kind == .sun || o.kind == .moon ? 22 : 10
                let rect = CGRect(x: o.screen.x - s.width / 2, y: o.screen.y + below, width: s.width, height: s.height)
                if rect.minY < topBand || taken.contains(where: { $0.intersects(rect.insetBy(dx: -3, dy: -1)) }) { continue }
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

            let pickRadius = min(size.width, size.height) * 0.07
            var picked = visible.min(by: { dist($0.screen, c) < dist($1.screen, c) })
            if let p = picked, dist(p.screen, c) >= pickRadius { picked = nil }

            if let t = model.target, let r = model.resolve(t, at: date) {
                let v = SIMD3<Float>(r.horizontal.vector)
                let ring = Color(red: 0.31, green: 0.80, blue: 0.81)
                let onScreen = proj.point(v).flatMap { p in
                    p.x > 0 && p.x < size.width && p.y > 0 && p.y < size.height ? p : nil
                }
                if let p = onScreen {
                    gc.stroke(Path(ellipseIn: CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40)),
                              with: .color(ring), lineWidth: 2)
                } else {
                    drawArrow(gc, toward: v, camera: cam, size: size, label: r.name, color: ring, pointing: model.pointing)
                }
                // a selected target owns the pill, on screen or not (it says where to look)
                picked = SkyObject(name: r.name, kind: r.kind ?? .star, magnitude: r.magnitude ?? .nan,
                                   horizontal: r.horizontal, screen: onScreen ?? c, hidden: r.horizontal.altitude < 0,
                                   rangeKm: r.rangeKm, detail: r.detail)
            }
            if let hit = picked { drawPill(gc, for: hit, size: size) }
        }
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// A selected satellite's path across the sky this pass: ±12 minutes,
    /// above the horizon, ticked every 30 s with the time each minute.
    private func drawTrack(_ gc: GraphicsContext, satellite id: Int, proj: Projector, size: CGSize) {
        guard let sat = model.satellites.satellite(id: id) else { return }
        let color = Color(red: 0.31, green: 0.80, blue: 0.81)
        var path = Path(), drawing = false
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        for step in stride(from: -720, through: 720, by: 15) {
            let t = date.addingTimeInterval(Double(step))
            guard let p = SatelliteFrame(date: t, observer: model.observer).position(of: sat),
                  p.horizontal.altitude > -0.5,
                  let pt = proj.point(refractHorizon(SIMD3<Float>(p.horizontal.vector))) else {
                drawing = false
                continue
            }
            if drawing { path.addLine(to: pt) } else { path.move(to: pt); drawing = true }
            // a LEO satellite crosses ~30° of sky a minute: dots every 30 s, times every minute
            if step % 30 == 0 && step != 0 {
                gc.fill(Path(ellipseIn: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)),
                        with: .color(color.opacity(0.8)))
            }
            if step % 60 == 0 && step != 0 {
                gc.draw(Text(f.string(from: t)).font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(color.opacity(0.75)), at: CGPoint(x: pt.x + 18, y: pt.y - 8))
            }
        }
        gc.stroke(path, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
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

    /// Which way to turn to find the target. Dragging: an arrow at the screen
    /// edge with the name. Pointing: Star Walk's arrowhead, 150 pt out from the
    /// centre where your eyes are while you sweep the phone around.
    private func drawArrow(_ gc: GraphicsContext, toward v: SIMD3<Float>, camera: Camera, size: CGSize,
                           label: String, color: Color, pointing: Bool) {
        let (r, u, f) = camera.basis
        // the way a person turns, not the great circle: something behind you and
        // low means "turn round", not "tip back over the zenith"
        let here = Horizontal(vector: SIMD3<Double>(f)), there = Horizontal(vector: SIMD3<Double>(v))
        func step(_ dAlt: Double, _ dAz: Double) -> SIMD3<Float> {
            SIMD3<Float>(Horizontal(altitude: here.altitude + dAlt, azimuth: here.azimuth + dAz).vector) - f
        }
        let dAz = remainder(there.azimuth - here.azimuth, 360) * cos(here.altitude * .pi / 180)
        let dAlt = there.altitude - here.altitude
        let turn = simd_normalize(step(0, 0.01)) * Float(dAz) + simd_normalize(step(0.01, 0)) * Float(dAlt)
        var d = CGVector(dx: CGFloat(simd_dot(turn, r)), dy: -CGFloat(simd_dot(turn, u)))
        let len = hypot(d.dx, d.dy)
        guard len > 1e-4 else { return }
        d = CGVector(dx: d.dx / len, dy: d.dy / len)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let side = CGVector(dx: -d.dy, dy: d.dx)
        func at(_ o: CGPoint, _ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: o.x + d.dx * along + side.dx * across, y: o.y + d.dy * along + side.dy * across)
        }
        if pointing {
            // measured from Jason's Star Walk screenshots: ~35 pt, light blue, notched
            let tip = at(c, min(150, min(size.width, size.height) / 2 - 80), 0)   // clear of the pill
            var a = Path()
            a.move(to: tip)
            a.addLine(to: at(tip, -30, 17))
            a.addLine(to: at(tip, -19, 0))
            a.addLine(to: at(tip, -30, -17))
            a.closeSubpath()
            gc.fill(a, with: .color(Color(red: 0.67, green: 0.78, blue: 1.0)))
            return
        }
        // where the ray from the centre leaves an inset rectangle
        let hw = size.width / 2 - 70, hh = size.height / 2 - 60
        let t = min(abs(d.dx) > 1e-4 ? hw / abs(d.dx) : .infinity, abs(d.dy) > 1e-4 ? hh / abs(d.dy) : .infinity)
        let tip = at(c, t, 0)
        let back = at(tip, -22, 0)
        var a = Path()
        a.move(to: tip)
        a.addLine(to: at(back, 0, 11))
        a.addLine(to: at(back, 0, -11))
        a.closeSubpath()
        gc.fill(a, with: .color(color))
        gc.draw(Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(color), at: at(back, -26, 0))
    }

    private func drawPill(_ gc: GraphicsContext, for o: SkyObject, size: CGSize) {
        let kind = switch o.kind {
        case .star: "Star"
        case .planet: "Planet"
        case .moon: "Moon"
        case .sun: "Sun"
        case .satellite: "Satellite"
        case .deepSky: "Deep sky"
        }
        let mag = o.magnitude.isNaN ? "" : String(format: " · mag %.1f", o.magnitude)
        let where_ = o.horizontal.altitude > 0
            ? String(format: "%.0f° up, %@", o.horizontal.altitude, compassPoint(o.horizontal.azimuth))
            : "below the horizon, " + compassPoint(o.horizontal.azimuth)
        // satellites' own detail already says how bright (or that they're in shadow)
        let head = o.detail.map { o.kind == .satellite ? $0 : $0 + mag } ?? (kind + mag)
        var detail = head + " · " + where_
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
                Button { model.timeBarOpen.toggle() } label: {
                    Label(timeText(model.date(at: t.date)), systemImage: "clock")
                        .foregroundStyle(model.timeTraveling ? Self.amber : .white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                Spacer()
                satellites(t.date)
                Text(String(format: "%.0f° FOV", model.camera.fov)).foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }

    /// Orbit data age: amber after 3 days, when predictions start drifting.
    @ViewBuilder private func satellites(_ now: Date) -> some View {
        if model.satellitesFetched != nil, !model.satellitesValid(at: model.date(at: now)) {
            Text("sats hidden · orbits don't reach this date").foregroundStyle(Self.amber)
        } else if let at = model.satellitesFetched {
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
        f.dateFormat = model.timeTraveling ? "yyyy-MM-dd HH:mm zzz" : "HH:mm"
        return (model.fixedDate != nil && model.timeOffset == 0 ? "Frozen " : "") + f.string(from: d)
    }
}
