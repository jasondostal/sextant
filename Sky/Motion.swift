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
            self.onUpdate?(Self.screenBasis(x: x, y: y, z: z))
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
    #else
    var available: Bool { false }
    func start() {}
    func stop() {}
    #endif

    /// Screen right/up in sky coordinates for the current landscape orientation.
    private static func screenBasis(x: SIMD3<Float>, y: SIMD3<Float>, z: SIMD3<Float>) -> Camera.Basis {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        // landscapeRight: the phone's top points left, so its +x side is up
        if scene?.effectiveGeometry.interfaceOrientation == .landscapeRight {
            return Camera.Basis(right: -y, up: x, forward: -z)
        }
        #endif
        return Camera.Basis(right: y, up: -x, forward: -z)
    }
}
