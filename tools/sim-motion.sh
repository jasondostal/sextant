#!/bin/zsh
# sim-motion.sh: runs point mode's orientation filter (Sky/Motion.swift, lifted out
# as-is) on a synthetic sweep from looking down to looking up, and on still-phone
# sensor noise. Prints the lag and the leftover wobble; exits 1 if the view fails to
# follow (lag over 5°) or doesn't damp the noise. Run after touching the filter.
set -e
here=${0:A:h}; out=$(mktemp -d)
python3 - "$here/../Sky/Motion.swift" "$out/sim.swift" <<'PY'
import sys
src = open(sys.argv[1]).read()
body = src[src.index('    static let stillCutoff'):src.index('    /// Screen right/up in sky coordinates')]
body = body.replace('Camera.Basis', 'Basis').replace('TimeInterval', 'Double').replace('private func smooth', 'func smooth')
open(sys.argv[2], 'w').write('''import Foundation
import simd
struct Basis { var right, up, forward: SIMD3<Float> }
final class F {
    var fov: () -> Double = { 75 }
    var smoothed: simd_quatf?
    var lastRaw: (q: simd_quatf, t: Double)?
    var speed: Float = 0
''' + body + '''
}
func basis(yaw: Float, pitch: Float) -> Basis {
    let m = simd_float3x3(simd_quatf(angle: yaw, axis: [0, 0, 1]) * simd_quatf(angle: pitch, axis: [1, 0, 0]))
    return Basis(right: m.columns.0, up: m.columns.1, forward: -m.columns.2)
}
func err(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { acos(min(1, simd_dot(a, b))) * 180 / .pi }
let f = F()
var lag: Float = 0
for i in 0..<210 {
    let t = Double(i) / 60, u = Float(min(1, max(0, (t - 1) / 1.5)))
    let target = basis(yaw: u * 2.09, pitch: 0.2 + u * 2.97)
    lag = max(lag, err(f.smooth(target, at: t).forward, target.forward))
}
var wobble: Float = 0
for i in 0..<120 {
    let n = Float.random(in: -1...1) * 0.0026
    let o = f.smooth(basis(yaw: 2.09 + n, pitch: 3.17 - n), at: 3.5 + Double(i) / 60)
    if i > 30 { wobble = max(wobble, err(o.forward, basis(yaw: 2.09, pitch: 3.17).forward)) }
}
print(String(format: "sweep down->up: worst lag %.2f°; still with ±0.15° noise: wobble %.3f°", lag, wobble))
exit(lag < 5 && wobble < 0.15 ? 0 : 1)
''')
PY
swiftc -O "$out/sim.swift" -o "$out/sim" && "$out/sim"
