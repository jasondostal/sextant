import Foundation
import simd

/// HYG v4.1 stars to magnitude 8, as packed by tools/gen-sky.py: 8 bytes a
/// star, little-endian, brightest first. uint16 RA (0…65535 = 0…24 h),
/// int16 Dec (±32767 = ±90°), int16 magnitude × 100, int16 B−V × 1000.
public struct StarCatalog: Sendable {
    public struct Star: Sendable {
        /// J2000 equatorial unit vector.
        public let direction: SIMD3<Float>
        public let magnitude: Float
        /// B−V colour index.
        public let colorIndex: Float
    }

    public let stars: [Star]
    /// Proper names for the brighter stars, by index into `stars`.
    public let names: [Int: String]

    public init(packed data: Data, names: [Int: String]) {
        var out: [Star] = []
        out.reserveCapacity(data.count / 8)
        data.withUnsafeBytes { raw in
            for i in 0..<(raw.count / 8) {
                let o = i * 8
                let ra = Double(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian) / 65535 * 24
                let dec = Double(raw.loadUnaligned(fromByteOffset: o + 2, as: Int16.self).littleEndian) / 32767 * 90
                let mag = Float(raw.loadUnaligned(fromByteOffset: o + 4, as: Int16.self).littleEndian) / 100
                let bv = Float(raw.loadUnaligned(fromByteOffset: o + 6, as: Int16.self).littleEndian) / 1000
                let v = equatorialVector(raHours: ra, decDegrees: dec)
                out.append(Star(direction: SIMD3<Float>(v), magnitude: mag, colorIndex: bv))
            }
        }
        stars = out
        self.names = names
    }

    /// Index of the first star fainter than `magnitude` (the catalog is sorted).
    public func count(brighterThan magnitude: Float) -> Int {
        var lo = 0, hi = stars.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if stars[mid].magnitude <= magnitude { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    public func index(named name: String) -> Int? {
        names.first { $0.value == name }?.key
    }
}

/// The fixed sky shipped with SkyCore: stars, constellation figures and the Milky Way.
public struct SkyData: Sendable {
    public struct Constellation: Sendable {
        public let name: String
        /// J2000 direction of the label.
        public let direction: SIMD3<Float>
        /// 1 = major, 3 = minor.
        public let rank: Int
    }

    public struct MilkyWayPoint: Sendable {
        public let direction: SIMD3<Float>
        /// 1 (faint outer outline) … 5 (brightest core).
        public let level: Int
    }

    public let catalog: StarCatalog
    /// Constellation stick figures as polylines of J2000 directions.
    public let lines: [[SIMD3<Float>]]
    /// Index into `constellations` of each polyline's constellation.
    public let lineOwners: [Int]
    public let constellations: [Constellation]
    public let milkyWay: [MilkyWayPoint]

    public static func load() throws -> SkyData {
        let base = Bundle.module.url(forResource: "Resources", withExtension: nil)!
        let packed = try Data(contentsOf: base.appendingPathComponent("stars.bin"))
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: base.appendingPathComponent("sky-data.json"))) as! [String: Any]

        var names: [Int: String] = [:]
        for pair in json["starNames"] as! [[Any]] {
            names[pair[0] as! Int] = pair[1] as? String
        }
        // d3-celestial stores RA as longitude in degrees.
        func dir(_ lon: Double, _ lat: Double) -> SIMD3<Float> {
            SIMD3<Float>(equatorialVector(raHours: lon / 15, decDegrees: lat))
        }
        let lines = (json["lines"] as! [[Double]]).map { flat in
            stride(from: 0, to: flat.count - 1, by: 2).map { dir(flat[$0], flat[$0 + 1]) }
        }
        let cons = (json["constellations"] as! [[Any]]).map {
            Constellation(name: $0[0] as! String,
                          direction: dir(($0[1] as! NSNumber).doubleValue, ($0[2] as! NSNumber).doubleValue),
                          rank: ($0[3] as! NSNumber).intValue)
        }
        let mw = (json["milkyWay"] as! [[NSNumber]]).map {
            MilkyWayPoint(direction: dir($0[0].doubleValue, $0[1].doubleValue), level: $0[2].intValue)
        }
        return SkyData(catalog: StarCatalog(packed: packed, names: names),
                       lines: lines, lineOwners: (json["lineOwners"] as! [NSNumber]).map(\.intValue),
                       constellations: cons, milkyWay: mw)
    }
}
