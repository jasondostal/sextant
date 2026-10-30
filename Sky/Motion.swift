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
            guard let self, let m = motion?.attitude.rotationMatrix else { return }
            let x = SIMD3<Float>(Float(m.m11), Float(m.m12), Float(m.m13))
            let y = SIMD3<Float>(Float(m.m21), Float(m.m22), Float(m.m23))
            let z = SIMD3<Float>(Float(m.m31), Float(m.m32), Float(m.m33))
            self.onUpdate?(self.smooth(Self.screenBasis(x: x, y: y, z: z)))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        smoothed = nil
    }
    #else
    var available: Bool { false }
    func start() {}
    func stop() {}
    #endif

    /// Adaptive low-pass on the orientation (the one-euro idea): a reading close to
    /// the last is mostly tremor and sensor noise, so it moves the view a little; a
    /// big change is you turning, so it comes through nearly at once. At 60 Hz,
    /// sitting still settles over ~0.2 s; a sweep lags by a frame or two.
    private func smooth(_ b: Camera.Basis) -> Camera.Basis {
        let raw = simd_quatf(simd_float3x3(columns: (b.right, b.up, b.forward)))
        guard var q = smoothed else {
            smoothed = raw
            return b
        }
        if simd_dot(q.vector, raw.vector) < 0 { q = simd_quatf(vector: -q.vector) }   // same hemisphere
        let step = 2 * acos(min(1, abs(simd_dot(q.vector, raw.vector)))) * 180 / .pi  // degrees
        let zoom = Float(min(1, max(0.25, fov() / 75)))
        let alpha = min(0.9, 0.07 * zoom + 0.6 * pow(step / 2.5, 1.6))
        q = simd_slerp(q, raw, alpha)
        smoothed = q
        let m = simd_float3x3(q)
        return Camera.Basis(right: m.columns.0, up: m.columns.1, forward: m.columns.2)
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
