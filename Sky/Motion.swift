import CoreMotion
import simd
#if os(iOS)
import UIKit
#endif

/// Point-at-the-sky mode. CoreMotion's xTrueNorthZVertical frame is x = true
/// north, z = up, so y = west: exactly SkyCore's horizon frame, and the
/// attitude matrix's rows are the phone's axes in sky coordinates, no
/// conversion needed. The camera looks out of the back of the phone.
final class MotionTracker {
    var onUpdate: ((Camera.Basis) -> Void)?
    /// The current field of view: zoomed in, a hand's tremor covers more of the
    /// screen, so the smoothing works harder.
    var fov: () -> Double = { 75 }
    private var smoothed: simd_quatf?
    private var lastRaw: (q: simd_quatf, t: TimeInterval)?
    private var speed: Float = 0          // deg/s, itself lightly filtered

    #if os(iOS)
    private let manager = CMMotionManager()
    var available: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard available else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        let frame: CMAttitudeReferenceFrame =
            CMMotionManager.availableAttitudeReferenceFrames().contains(.xTrueNorthZVertical)
                ? .xTrueNorthZVertical : .xMagneticNorthZVertical
        manager.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] motion, _ in
            guard let self, let motion, case let m = motion.attitude.rotationMatrix else { return }
            let x = SIMD3<Float>(Float(m.m11), Float(m.m12), Float(m.m13))
            let y = SIMD3<Float>(Float(m.m21), Float(m.m22), Float(m.m23))
            let z = SIMD3<Float>(Float(m.m31), Float(m.m32), Float(m.m33))
            self.onUpdate?(self.smooth(Self.screenBasis(x: x, y: y, z: z), at: motion.timestamp))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        smoothed = nil
        lastRaw = nil
        speed = 0
    }
    #else
    var available: Bool { false }
    func start() {}
    func stop() {}
    #endif

    /// The one-euro filter on the orientation: its cutoff rises with how fast the
    /// phone is turning. Held still, it's low (~1.2 Hz) and tremor and sensor noise
    /// are smoothed out; turning, it opens up in proportion, so a slow pan lags by
    /// ~40 ms and a quick sweep by ~10 ms. Zoomed in, the still cutoff drops further.
    static let stillCutoff: Float = 1.2       // Hz
    static let speedGain: Float = 0.5         // Hz per deg/s

    private func smooth(_ b: Camera.Basis, at t: TimeInterval) -> Camera.Basis {
        // right, up, backward is a proper rotation (right, up, forward is a mirror
        // image, and a quaternion made from one is garbage)
        let raw = simd_quatf(simd_float3x3(columns: (b.right, b.up, -b.forward)))
        guard var q = smoothed, let last = lastRaw, t > last.t else {
            smoothed = raw
            lastRaw = (raw, t)
            return b
        }
        let dt = Float(min(0.1, t - last.t))
        func degrees(_ a: simd_quatf, _ b: simd_quatf) -> Float {
            2 * acos(min(1, abs(simd_dot(a.vector, b.vector)))) * 180 / .pi
        }
        func alpha(_ cutoff: Float) -> Float { 1 / (1 + 1 / (2 * .pi * cutoff * dt)) }
        // how fast it's really turning, from the raw readings, smoothed at 1 Hz
        speed += (degrees(last.q, raw) / dt - speed) * alpha(1)
        lastRaw = (raw, t)
        let zoom = Float(min(1, max(0.4, fov() / 75)))
        if simd_dot(q.vector, raw.vector) < 0 { q = simd_quatf(vector: -q.vector) }   // same hemisphere
        q = simd_slerp(q, raw, alpha(Self.stillCutoff * zoom + Self.speedGain * speed))
        smoothed = q
        let m = simd_float3x3(q)
        return Camera.Basis(right: m.columns.0, up: m.columns.1, forward: -m.columns.2)
    }

    /// Screen right/up in sky coordinates for the current interface orientation.
    private static func screenBasis(x: SIMD3<Float>, y: SIMD3<Float>, z: SIMD3<Float>) -> Camera.Basis {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        switch scene?.effectiveGeometry.interfaceOrientation {
        case .portrait?:
            return Camera.Basis(right: x, up: y, forward: -z)
        case .landscapeRight?:
            // the phone's top points left, so its +x side is up
            return Camera.Basis(right: -y, up: x, forward: -z)
        default:
            break
        }
        #endif
        return Camera.Basis(right: y, up: -x, forward: -z)
    }
}
