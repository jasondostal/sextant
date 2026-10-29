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

/// Draws the sky in five passes: background, Milky Way, constellation
/// figures, stars, bodies, then the ground over everything below the hills.
final class Renderer: NSObject, MTKViewDelegate {
    let model: SkyModel
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let sky, ground, stars, glows, lines: MTLRenderPipelineState
    private let starBuffer, milkyWayBuffer, lineBuffer: MTLBuffer
    private let starCount, milkyWayCount, lineVertexCount: Int

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

        let data = model.sky
        var packed: [Float] = []
        packed.reserveCapacity(data.catalog.stars.count * 5)
        for s in data.catalog.stars {
            packed += [s.direction.x, s.direction.y, s.direction.z, s.magnitude, s.colorIndex]
        }
        starCount = data.catalog.stars.count
        starBuffer = device.makeBuffer(bytes: packed, length: packed.count * 4)!

        // Milky Way: ~1,700 soft 4.5° blobs, brighter toward the core levels
        var mw: [Float] = []
        for p in data.milkyWay {
            let a = 0.010 + 0.011 * Float(p.level)
            mw += [p.direction.x, p.direction.y, p.direction.z, 4.5, 0.62 * a, 0.70 * a, 0.95 * a, a]
        }
        milkyWayCount = data.milkyWay.count
        milkyWayBuffer = device.makeBuffer(bytes: mw, length: mw.count * 4)!

        var seg: [Float] = []
        for line in data.lines {
            for (a, b) in zip(line, line.dropFirst()) {
                seg += [a.x, a.y, a.z, b.x, b.y, b.z]
            }
        }
        lineVertexCount = seg.count / 3
        lineBuffer = device.makeBuffer(bytes: seg, length: seg.count * 4)!
        super.init()
    }

    private enum Blend { case none, over, additive }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        let date = model.now
        let frame = model.frame(at: date)
        let bodies = model.bodies(at: date)
        let cam = model.camera
        let scale = Float(size.height / max(view.bounds.height, 1))

        let sun = bodies.first { $0.body == .sun }!
        // 0 by day, 1 once the sun is 15° down; stars come through in between
        let darkness = Float(min(1, max(0, (-sun.geometric.altitude - 1) / 14)))
        let vp = cam.viewProj(size)
        // fainter stars as you zoom in, like a pair of binoculars
        let limit = Float(min(8.0, 6.3 + 2.0 * log10(max(1, 75 / cam.fov))))
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

        var bodyGlows = Self.glows(bodies, pixelsPerDegree: cam.perDegree(size) / Double(scale))

        pass.colorAttachments[0].loadAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)

        enc.setRenderPipelineState(sky)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        var catalog: UInt32 = 1
        enc.setRenderPipelineState(glows)
        enc.setVertexBuffer(milkyWayBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setVertexBytes(&catalog, length: 4, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: milkyWayCount)

        enc.setRenderPipelineState(lines)
        enc.setVertexBuffer(lineBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineVertexCount)

        enc.setRenderPipelineState(stars)
        enc.setVertexBuffer(starBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                           instanceCount: model.sky.catalog.count(brighterThan: limit))

        catalog = 0
        enc.setRenderPipelineState(glows)
        enc.setVertexBytes(&bodyGlows, length: bodyGlows.count * 4, index: 0)
        enc.setVertexBytes(&catalog, length: 4, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: bodies.count)

        enc.setRenderPipelineState(ground)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Bodies are already topocentric and in the horizon frame, so they're
    /// sent each frame as glows with a pixel radius (a few hundred bytes).
    private static func glows(_ bodies: [BodyPosition], pixelsPerDegree: Double) -> [Float] {
        bodies.flatMap { b -> [Float] in
            let v = SIMD3<Float>(b.geometric.vector)
            let (radius, c) = look(b, pixelsPerDegree: pixelsPerDegree)
            return [v.x, v.y, v.z, radius, c.x, c.y, c.z, c.w]
        }
    }

    static func look(_ b: BodyPosition, pixelsPerDegree: Double) -> (Float, SIMD4<Float>) {
        switch b.body {
        case .sun:
            return (Float(max(14, 0.53 * pixelsPerDegree)), SIMD4(1.0, 0.92, 0.70, 1))
        case .moon:
            // brightness follows the phase so a thin crescent doesn't blaze
            let lit = Float(0.25 + 0.75 * b.phase)
            return (Float(max(11, 0.52 * pixelsPerDegree)), SIMD4(0.95, 0.94, 0.88, 1) * lit)
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
