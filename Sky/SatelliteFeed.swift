import Foundation
import SkyCore

/// CelesTrak orbits on the phone. The cached copy is used straight away; a
/// fresh one is fetched when it's over 12 h old, at most every 2 h (CelesTrak
/// answers 403 to repeats of unchanged data, and asks clients to cache).
final class SatelliteFeed {
    static let groups = ["visual", "active"]
    private static let url = "https://celestrak.org/NORAD/elements/gp.php?GROUP=%@&FORMAT=json"
    private static let staleAfter: TimeInterval = 12 * 3600
    private static let retryAfter: TimeInterval = 2 * 3600

    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("celestrak")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Called on the main queue with each catalog built (cached, then fresh) and when it was fetched.
    var onCatalog: ((SatelliteCatalog, Date) -> Void)?

    func start() {
        Task.detached(priority: .utility) { [self] in
            if let (cat, fetched) = loadCached() { publish(cat, fetched) }
            guard needsRefresh() else { return }
            UserDefaults.standard.set(Date(), forKey: "celestrakLastAttempt")
            do {
                var fresh: [Data] = []
                for g in Self.groups {
                    var req = URLRequest(url: URL(string: String(format: Self.url, g))!)
                    req.setValue("Sky (personal iOS app)", forHTTPHeaderField: "User-Agent")
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200, data.first == UInt8(ascii: "[") else {
                        throw URLError(.badServerResponse)
                    }
                    fresh.append(data)
                }
                let cat = try SatelliteCatalog(groups: fresh)
                guard cat.satellites.count > 1000 else { return }     // something's wrong; keep the old
                for (g, d) in zip(Self.groups, fresh) {
                    try d.write(to: file(g), options: .atomic)
                }
                publish(cat, Date())
            } catch {
                // offline or refused: the cached orbits stay in use (the readout shows their age)
            }
        }
    }

    private func file(_ group: String) -> URL { dir.appendingPathComponent("gp-\(group).json") }

    private func fetchedAt() -> Date? {
        let dates = Self.groups.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: file($0).path))?[.modificationDate] as? Date
        }
        return dates.count == Self.groups.count ? dates.min() : nil
    }

    private func loadCached() -> (SatelliteCatalog, Date)? {
        guard let at = fetchedAt() else { return nil }
        let data = Self.groups.compactMap { try? Data(contentsOf: file($0)) }
        guard data.count == Self.groups.count, let cat = try? SatelliteCatalog(groups: data) else { return nil }
        return (cat, at)
    }

    private func needsRefresh() -> Bool {
        if let last = UserDefaults.standard.object(forKey: "celestrakLastAttempt") as? Date,
           Date().timeIntervalSince(last) < Self.retryAfter { return false }
        guard let at = fetchedAt() else { return true }
        return Date().timeIntervalSince(at) > Self.staleAfter
    }

    private func publish(_ cat: SatelliteCatalog, _ at: Date) {
        DispatchQueue.main.async { self.onCatalog?(cat, at) }
    }
}

/// Which satellites to propagate each frame. A background sweep over the whole
/// catalog every 2 s keeps the ones near or above the horizon (a few hundred
/// of ~16k); the frame loop then only propagates those.
final class SatelliteTracker {
    struct Visible {
        let satellite: Satellite
        let position: SatellitePosition
    }

    private let lock = NSLock()
    private var catalog: SatelliteCatalog?
    private var candidates: [Satellite] = []
    private var sweeping = false
    private var lastSweep: (Date, Observer)?
    private var generation = 0                  // bumped by each sweep, so a frozen clock still sees it
    private var cache: (Date, Int, [Visible])?

    private var byId: [Int: Satellite] = [:]

    var count: Int { lock.withLock { catalog?.satellites.count ?? 0 } }
    var all: [Satellite] { lock.withLock { catalog?.satellites ?? [] } }
    func satellite(id: Int) -> Satellite? { lock.withLock { byId[id] } }

    func setCatalog(_ c: SatelliteCatalog) {
        let ids = Dictionary(c.satellites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        lock.withLock {
            catalog = c
            byId = ids
            lastSweep = nil
        }
    }

    /// Satellites above the horizon at `date`, sunlit or not, brightest first.
    func positions(at date: Date, observer: Observer) -> [Visible] {
        sweepIfDue(date, observer)
        let (list, gen) = lock.withLock { (candidates, generation) }
        if let (t, g, v) = cache, g == gen, abs(t.timeIntervalSince(date)) < 0.005 { return v }
        let frame = SatelliteFrame(date: date, observer: observer)
        let v = list.compactMap { s -> Visible? in
            guard let p = frame.position(of: s), p.horizontal.altitude > -1 else { return nil }
            return Visible(satellite: s, position: p)
        }
        cache = (date, gen, v)
        return v
    }

    private func sweepIfDue(_ date: Date, _ observer: Observer) {
        let due = lock.withLock { () -> SatelliteCatalog? in
            guard !sweeping, let c = catalog else { return nil }
            if let (t, o) = lastSweep, o == observer, abs(date.timeIntervalSince(t)) < 2 { return nil }
            sweeping = true
            lastSweep = (date, observer)
            return c
        }
        guard let cat = due else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // a satellite well below the horizon now can't be up within the next few seconds
            let frame = SatelliteFrame(date: date, observer: observer)
            let near = cat.satellites.filter { s in
                guard let p = frame.position(of: s) else { return false }
                return p.horizontal.altitude > -8
            }
            self.lock.withLock {
                self.candidates = near
                self.generation += 1
                self.sweeping = false
            }
        }
    }
}
