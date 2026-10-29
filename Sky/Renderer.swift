import MetalKit
import simd
import SkyCore

/// Mirrors `Uniforms` in Shaders.metal; field order and simd types keep the
/// layouts identical (float3 and float3x3 columns are 16-byte aligned on both sides).
struct Uniforms {
    var viewProj: simd_float4x4
    var invViewProj: simd_float4x4
    var eqjToHor: simd_float3x3
    var beta: SIMD3<Float>
    var sunDir: SIMD3<Float>
    var viewport: SIMD2<Float>
    var pxPerDeg: Float
    var limitMag: Float
    var darkness: Float
    var scale: Float
}

/// Draws the sky in five passes: background (with the Milky Way), constellation
/// figures, stars, bodies, then the ridge and lake over everything below the hills;
/// in night mode a sixth turns it all red.
final class Renderer: NSObject, MTKViewDelegate {
    let model: SkyModel
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let sky, ground, stars, glows, lines, night: MTLRenderPipelineState
    private let starBuffer, lineBuffer: MTLBuffer
    private let starCount: Int
    /// Each constellation's figure: where its vertices sit in `lineBuffer`, and its segments (J2000).
    private let figures: [(range: Range<Int>, segments: [(SIMD3<Float>, SIMD3<Float>)])]
    /// How lit each figure is right now, easing toward 1 for the focused one and 0 for the rest.
    private var fade: [Float]
    private var focused: Int?
    private var lastFrame = Date()
    private let milkyWay: MTLTexture
    /// Per-frame satellite glows; three so the CPU never writes one the GPU is reading.
    private let satBuffers: [MTLBuffer]
    private var satFrame = 0
    private let inFlight = DispatchSemaphore(value: 3)
    static let maxSatellites = 4096

    init(view: MTKView, model: SkyModel) {
        self.model = model
        let device = view.device!
        self.device = device
        queue = device.makeCommandQueue()!
        let library = device.makeDefaultLibrary()!

        func pipeline(_ vertex: String, _ fragment: String, blend: Blend) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let a = d.colorAttachments[0]!
            a.pixelFormat = view.colorPixelFormat
            if blend != .none {
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = blend == .additive ? .one : .sourceAlpha
                a.destinationRGBBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        sky = pipeline("screenVertex", "skyFragment", blend: .none)
        ground = pipeline("screenVertex", "groundFragment", blend: .over)
        stars = pipeline("starVertex", "starFragment", blend: .additive)
        glows = pipeline("glowVertex", "glowFragment", blend: .additive)
        lines = pipeline("lineVertex", "lineFragment", blend: .additive)
        night = pipeline("screenVertex", "nightFragment", blend: .none)

        let data = model.sky
        var packed: [Float] = []
        packed.reserveCapacity(data.catalog.stars.count * 5)
        for s in data.catalog.stars {
            packed += [s.direction.x, s.direction.y, s.direction.z, s.magnitude, s.colorIndex]
        }
        starCount = data.catalog.stars.count
        starBuffer = device.makeBuffer(bytes: packed, length: packed.count * 4)!

        // greyscale Milky Way glow (tools/gen-milkyway.py), sampled by the sky pass
        milkyWay = try! MTKTextureLoader(device: device).newTexture(
            URL: Bundle.main.url(forResource: "milkyway", withExtension: "png")!,
            options: [.SRGB: false, .generateMipmaps: false])

        // vertex pairs grouped by constellation, so one figure can be drawn on its own
        var seg: [Float] = []
        var figs: [(range: Range<Int>, segments: [(SIMD3<Float>, SIMD3<Float>)])] = []
        for c in data.constellations.indices {
            let first = seg.count / 3
            var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
            for (line, owner) in zip(data.lines, data.lineOwners) where owner == c {
                for (a, b) in zip(line, line.dropFirst()) {
                    seg += [a.x, a.y, a.z, b.x, b.y, b.z]
                    segments.append((a, b))
                }
            }
            figs.append((first..<(seg.count / 3), segments))
        }
        figures = figs
        fade = Array(repeating: 0, count: figs.count)
        lineBuffer = device.makeBuffer(bytes: seg, length: seg.count * 4)!
        satBuffers = (0..<3).map { _ in device.makeBuffer(length: Self.maxSatellites * 48, options: .storageModeShared)! }
        super.init()
    }

    private enum Blend { case none, over, additive }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        let date = model.now
        model.tick(date)
        let frame = model.frame(at: date)
        let bodies = model.bodies(at: date)
        let cam = model.camera
        let scale = Float(size.height / max(view.bounds.height, 1))

        let sun = bodies.first { $0.body == .sun }!
        // 0 by day, 1 once the sun is 15° down; stars come through in between
        let darkness = Float(min(1, max(0, (-sun.geometric.altitude - 1) / 14)))
        let vp = cam.viewProj(size)
        let limit = Float(model.starLimit(fov: cam.fov))
        var u = Uniforms(
            viewProj: vp, invViewProj: vp.inverse,
            eqjToHor: simd_float3x3(
                SIMD3<Float>(frame.eqjToHor.columns.0), SIMD3<Float>(frame.eqjToHor.columns.1),
                SIMD3<Float>(frame.eqjToHor.columns.2)),
            beta: SIMD3<Float>(frame.beta),
            sunDir: SIMD3<Float>(sun.apparent.vector),
            viewport: SIMD2(Float(size.width), Float(size.height)),
            pxPerDeg: Float(cam.perDegree(size)),
            limitMag: limit, darkness: darkness, scale: scale)

        var bodyGlows = Self.glows(bodies, pixelsPerDegree: cam.perDegree(size) / Double(scale), camera: cam)
        inFlight.wait()
        let satBuffer = satBuffers[satFrame % 3]
        satFrame += 1
        let satCount = Self.writeSatellites(model.visibleSatellites(at: date), into: satBuffer)

        pass.colorAttachments[0].loadAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)

        enc.setRenderPipelineState(sky)
        enc.setFragmentTexture(milkyWay, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setRenderPipelineState(lines)
        enc.setVertexBuffer(lineBuffer, offset: 0, index: 0)
        drawFigures(enc, date: date, darkness: u.darkness)

        enc.setRenderPipelineState(stars)
        enc.setVertexBuffer(starBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                           instanceCount: model.sky.catalog.count(brighterThan: limit))

        var catalog: UInt32 = 0
        enc.setRenderPipelineState(glows)
        enc.setVertexBytes(&bodyGlows, length: bodyGlows.count * 4, index: 0)
        enc.setVertexBytes(&catalog, length: 4, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: bodies.count)

        if satCount > 0 {
            enc.setVertexBuffer(satBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: satCount)
        }

        enc.setRenderPipelineState(ground)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if model.nightMode {
            enc.setRenderPipelineState(night)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        cmd.commit()
    }

    /// Auto: the figure you're looking at (or the selected object sits in) fades in
    /// bright and the rest fade out. Always: all dim, that one bright. Never: none.
    private func drawFigures(_ enc: MTLRenderCommandEncoder, date: Date, darkness: Float) {
        let now = Date()
        let dt = Float(min(0.1, now.timeIntervalSince(lastFrame)))
        lastFrame = now
        let mode = model.lineMode
        if mode == .never { return }

        // the point of interest, back in J2000 (refraction doesn't matter at this scale)
        let toEqj = simd_transpose(model.frame(at: date).eqjToHor)
        var look = SIMD3<Float>(toEqj * SIMD3<Double>(model.camera.basis.forward))
        if let t = model.target, let r = model.resolve(t, at: date) {
            look = SIMD3<Float>(toEqj * r.horizontal.vector)
        }
        focused = nearestFigure(to: look, current: focused)

        for i in fade.indices {
            let goal: Float = i == focused ? 1 : 0
            fade[i] += (goal - fade[i]) * min(1, dt * 6)          // ~0.4 s ease
        }
        // dim figures fade with the sky; the focused one stays visible in daylight, like Star Walk's
        let dim = 0.28 * darkness, bright = 0.85 * max(darkness, 0.5)
        for (i, f) in figures.enumerated() where !f.range.isEmpty {
            var b = mode == .always ? dim + (bright - dim) * fade[i] : bright * fade[i]
            guard b > 0.01 else { continue }
            enc.setVertexBytes(&b, length: 4, index: 2)
            enc.drawPrimitives(type: .line, vertexStart: f.range.lowerBound, vertexCount: f.range.count)
        }
    }

    /// The figure whose nearest segment is closest to `p`, within 12°; a new one
    /// must beat the current by 1° so the lines don't flicker between neighbours.
    private func nearestFigure(to p: SIMD3<Float>, current: Int?) -> Int? {
        func distance(_ i: Int) -> Float {
            figures[i].segments.map { a, b -> Float in
                let n = simd_normalize(simd_cross(a, b))
                let q = simd_normalize(p - simd_dot(p, n) * n)            // p projected onto the arc's great circle
                let onArc = simd_dot(simd_cross(a, q), n) >= 0 && simd_dot(simd_cross(q, b), n) >= 0
                return onArc ? asin(min(1, abs(simd_dot(p, n))))
                             : min(acos(min(1, simd_dot(p, a))), acos(min(1, simd_dot(p, b))))
            }.min() ?? .infinity
        }
        let d = figures.indices.map(distance)
        guard let b = d.indices.min(by: { d[$0] < d[$1] }) else { return nil }
        if let c = current, c != b, d[c] < d[b] + Float.pi / 180 { return c }
        return d[b] < 12 * Float.pi / 180 ? b : nil
    }

    /// Bodies are already topocentric and in the horizon frame, so they're
    /// sent each frame as glows with a pixel radius (a few hundred bytes).
    private static func glows(_ bodies: [BodyPosition], pixelsPerDegree: Double, camera: Camera) -> [Float] {
        let sun = SIMD3<Float>(bodies.first { $0.body == .sun }!.geometric.vector)
        let (right, up, _) = camera.basis
        return bodies.flatMap { b -> [Float] in
            let v = SIMD3<Float>(b.geometric.vector)
            let (radius, c) = look(b, pixelsPerDegree: pixelsPerDegree)
            var phase: [Float] = [0, 0, 0, 0]
            if b.body == .moon {
                // which way the lit limb faces on screen, and how much is lit (cos i = 2k − 1)
                let toward = sun - simd_dot(sun, v) * v
                phase = [simd_dot(toward, right), simd_dot(toward, up), Float(2 * b.phase - 1), 1]
            }
            return [v.x, v.y, v.z, radius, c.x, c.y, c.z, c.w] + phase
        }
    }

    /// Satellites as small crisp dots, sized and dimmed by magnitude, a cool white
    /// like Star Walk's. Directions are horizon-frame, so they go in as bodies do.
    private static func writeSatellites(_ sats: [SatelliteTracker.Visible], into buffer: MTLBuffer) -> Int {
        let n = min(sats.count, maxSatellites)
        let p = buffer.contents().bindMemory(to: Float.self, capacity: n * 12)
        for i in 0..<n {
            let s = sats[i].position
            let v = SIMD3<Float>(s.horizontal.vector)
            let m = Float(s.magnitude)
            let a = min(1, max(0.6, (7 - m) / 4))
            let o = i * 12
            p[o] = v.x; p[o + 1] = v.y; p[o + 2] = v.z
            p[o + 3] = min(5.5, max(2.6, 4.6 - 0.45 * m))
            p[o + 4] = 0.88 * a; p[o + 5] = 0.97 * a; p[o + 6] = 1.0 * a; p[o + 7] = a
            p[o + 8] = 0; p[o + 9] = 0; p[o + 10] = 0; p[o + 11] = 0
        }
        return n
    }

    static func look(_ b: BodyPosition, pixelsPerDegree: Double) -> (Float, SIMD4<Float>) {
        switch b.body {
        case .sun:
            return (Float(max(14, 0.53 * pixelsPerDegree)), SIMD4(1.0, 0.92, 0.70, 1))
        case .moon:
            // the shader draws the phase; drawn a little larger than life, like Star Walk
            return (Float(max(17, 0.6 * pixelsPerDegree)), SIMD4(0.95, 0.94, 0.88, 1))
        default:
            let tint: SIMD3<Float> = switch b.body {
            case .mars: SIMD3(1.0, 0.62, 0.45)
            case .jupiter: SIMD3(1.0, 0.93, 0.82)
            case .saturn: SIMD3(1.0, 0.88, 0.62)
            case .venus: SIMD3(1.0, 0.98, 0.90)
            case .uranus, .neptune: SIMD3(0.70, 0.88, 1.0)
            default: SIMD3(0.92, 0.90, 0.86)
            }
            let r = Float(min(9, max(2.5, 5.5 - 0.9 * b.magnitude)))
            let a = Float(min(1, max(0.35, (7 - b.magnitude) / 6)))
            return (r, SIMD4(tint * a, a))
        }
    }
}
