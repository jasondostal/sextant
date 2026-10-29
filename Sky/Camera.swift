import CoreGraphics
import Foundation
import simd
import SkyCore

/// Where the view points, as a rectilinear (pinhole) camera at the centre of
/// the sky sphere. Straight lines stay straight, as in Star Walk; that is the
/// opposite of the old web build's fisheye.
struct Camera: Equatable {
    /// Degrees clockwise from true north.
    var azimuth: Double = 180
    /// Degrees above the horizon of the view centre.
    var altitude: Double = 25
    /// Field of view across the long side of the screen, degrees.
    var fov: Double = 75
    /// Set while the phone is being pointed at the sky: screen axes straight
    /// from the motion sensors, roll included. Azimuth/altitude are ignored.
    var attitude: Basis?

    struct Basis: Equatable {
        var right, up, forward: SIMD3<Float>
    }

    static let fovRange = 8.0...110.0

    /// Camera axes in the horizon frame (x = north, y = west, z = zenith).
    var basis: (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        if let a = attitude { return (a.right, a.up, a.forward) }
        let f = SIMD3<Float>(Horizontal(altitude: altitude, azimuth: azimuth).vector)
        // looking straight up or down, any heading works for "right"
        let zenith = SIMD3<Float>(0, 0, 1)
        var r = simd_cross(f, zenith)
        if simd_length(r) < 1e-4 {
            r = SIMD3<Float>(Horizontal(altitude: 0, azimuth: azimuth + 90).vector)
        }
        r = simd_normalize(r)
        return (r, simd_cross(r, f), f)
    }

    /// Vertical field of view in degrees for a viewport.
    func verticalFov(_ size: CGSize) -> Double {
        let long = max(size.width, size.height), short = min(size.width, size.height)
        let tanLong = tan(fov / 2 * .pi / 180)
        let tanV = size.width >= size.height ? tanLong * short / long : tanLong
        return 2 * atan(tanV) * 180 / .pi
    }

    func viewProj(_ size: CGSize) -> simd_float4x4 {
        let (r, u, f) = basis
        let view = simd_float4x4(rows: [
            SIMD4(r, 0), SIMD4(u, 0), SIMD4(-f, 0), SIMD4(0, 0, 0, 1),
        ])
        let aspect = Float(size.width / max(size.height, 1))
        let ys = 1 / Float(tan(verticalFov(size) / 2 * .pi / 180))
        let xs = ys / aspect
        let n: Float = 0.01, far: Float = 10
        let proj = simd_float4x4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, far / (n - far), -1),
            SIMD4(0, 0, n * far / (n - far), 0)))
        return proj * view
    }

    /// Pixels (or points) per degree at the centre of the view.
    func perDegree(_ size: CGSize) -> Double {
        let half = verticalFov(size) / 2 * .pi / 180
        return Double(size.height) / 2 / tan(half) * .pi / 180
    }
}

/// Projects horizon-frame directions to view coordinates (points, y down).
struct Projector {
    let matrix: simd_float4x4
    let size: CGSize

    init(camera: Camera, size: CGSize) {
        matrix = camera.viewProj(size)
        self.size = size
    }

    func point(_ h: SIMD3<Float>) -> CGPoint? {
        let c = matrix * SIMD4(h, 1)
        guard c.w > 1e-4 else { return nil }
        let x = CGFloat(c.x / c.w), y = CGFloat(c.y / c.w)
        guard abs(x) < 1.3, abs(y) < 1.3 else { return nil }
        return CGPoint(x: (x + 1) / 2 * size.width, y: (1 - y) / 2 * size.height)
    }
}

/// The eye's refraction lift, matching `refractHorizon` in Shaders.metal so
/// labels sit on their dots near the horizon.
func refractHorizon(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let alt = asin(max(-1, min(1, Double(v.z)))) * 180 / .pi
    guard alt > -1.5, alt < 85 else { return v }
    let r = refraction(atGeometricAltitude: alt)
    let na = (alt + r) * .pi / 180
    let h = simd_normalize(SIMD2(v.x, v.y))
    return SIMD3(h * Float(cos(na)), Float(sin(na)))
}
