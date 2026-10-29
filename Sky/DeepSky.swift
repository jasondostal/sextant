import Foundation
import SkyCore

/// The famous clusters, nebulae and galaxies: the ones worth binoculars or a
/// dark site. J2000 positions; magnitudes are integrated (spread out, so they
/// look fainter than a star of the same number).
struct DeepSkyObject {
    let name: String
    /// Messier/other designation, searchable.
    let designation: String
    let kind: String
    let raHours: Double
    let decDegrees: Double
    let magnitude: Double

    var direction: SIMD3<Double> { equatorialVector(raHours: raHours, decDegrees: decDegrees) }

    static let all: [DeepSkyObject] = [
        .init(name: "Pleiades", designation: "M45 Seven Sisters", kind: "Open cluster", raHours: 3.7833, decDegrees: 24.117, magnitude: 1.6),
        .init(name: "Hyades", designation: "Mel 25", kind: "Open cluster", raHours: 4.45, decDegrees: 15.87, magnitude: 0.5),
        .init(name: "Andromeda Galaxy", designation: "M31", kind: "Galaxy", raHours: 0.7123, decDegrees: 41.269, magnitude: 3.4),
        .init(name: "Triangulum Galaxy", designation: "M33", kind: "Galaxy", raHours: 1.5641, decDegrees: 30.660, magnitude: 5.7),
        .init(name: "Orion Nebula", designation: "M42", kind: "Nebula", raHours: 5.5881, decDegrees: -5.391, magnitude: 4.0),
        .init(name: "Beehive Cluster", designation: "M44 Praesepe", kind: "Open cluster", raHours: 8.67, decDegrees: 19.67, magnitude: 3.7),
        .init(name: "Double Cluster", designation: "NGC 869 NGC 884", kind: "Open clusters", raHours: 2.3333, decDegrees: 57.13, magnitude: 3.7),
        .init(name: "Hercules Cluster", designation: "M13", kind: "Globular cluster", raHours: 16.6948, decDegrees: 36.461, magnitude: 5.8),
        .init(name: "Lagoon Nebula", designation: "M8", kind: "Nebula", raHours: 18.0631, decDegrees: -24.383, magnitude: 6.0),
        .init(name: "Eagle Nebula", designation: "M16", kind: "Nebula", raHours: 18.313, decDegrees: -13.807, magnitude: 6.0),
        .init(name: "Wild Duck Cluster", designation: "M11", kind: "Open cluster", raHours: 18.8513, decDegrees: -6.267, magnitude: 5.8),
        .init(name: "Ring Nebula", designation: "M57", kind: "Planetary nebula", raHours: 18.893, decDegrees: 33.029, magnitude: 8.8),
        .init(name: "Dumbbell Nebula", designation: "M27", kind: "Planetary nebula", raHours: 19.9934, decDegrees: 22.721, magnitude: 7.5),
        .init(name: "Coathanger", designation: "Brocchi's Cluster Cr 399", kind: "Asterism", raHours: 19.4167, decDegrees: 20.18, magnitude: 3.6),
        .init(name: "Whirlpool Galaxy", designation: "M51", kind: "Galaxy", raHours: 13.498, decDegrees: 47.195, magnitude: 8.4),
        .init(name: "Bode's Galaxy", designation: "M81", kind: "Galaxy", raHours: 9.9259, decDegrees: 69.065, magnitude: 6.9),
        .init(name: "Omega Centauri", designation: "NGC 5139", kind: "Globular cluster", raHours: 13.4465, decDegrees: -47.479, magnitude: 3.9),
        .init(name: "Carina Nebula", designation: "NGC 3372", kind: "Nebula", raHours: 10.75, decDegrees: -59.87, magnitude: 1.0),
        .init(name: "Large Magellanic Cloud", designation: "LMC", kind: "Galaxy", raHours: 5.3929, decDegrees: -69.756, magnitude: 0.9),
        .init(name: "Small Magellanic Cloud", designation: "SMC", kind: "Galaxy", raHours: 0.877, decDegrees: -72.829, magnitude: 2.7),
        .init(name: "47 Tucanae", designation: "NGC 104", kind: "Globular cluster", raHours: 0.4014, decDegrees: -72.081, magnitude: 4.1),
    ]
}
