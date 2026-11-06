import Foundation
import SkyCore

/// Comet orbits from the IAU Minor Planet Center. A snapshot ships in SkyCore;
/// a fresh file (~165 KB) is fetched when the cached one is over a week old, at
/// most once a day. Comet elements change slowly, except for a bright comet
/// being re-measured, which a weekly refresh catches.
final class CometFeed {
    private static let staleAfter: TimeInterval = 7 * 86400
    private static let retryAfter: TimeInterval = 86400

    private let file: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("mpc")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("CometEls.txt")
    }()

    /// Called on the main queue with every comet in the file (cached, then fresh).
    var onComets: (([Comet]) -> Void)?

    func start() {
        Task.detached(priority: .utility) { [self] in
            if let text = try? String(contentsOf: file, encoding: .ascii) { publish(CometCatalog.parse(text)) }
            let age = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            let last = UserDefaults.standard.object(forKey: "mpcLastAttempt") as? Date ?? .distantPast
            guard age > Self.staleAfter, Date().timeIntervalSince(last) > Self.retryAfter else { return }
            UserDefaults.standard.set(Date(), forKey: "mpcLastAttempt")
            do {
                var req = URLRequest(url: CometCatalog.sourceURL)
                req.setValue("Sextant/1.1 (iOS; https://ducktyping.dev/sextant)", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .ascii) else { return }
                let comets = CometCatalog.parse(text)
                guard comets.count > 300 else { return }        // something's wrong; keep the old
                try data.write(to: file, options: .atomic)
                publish(comets)
            } catch {
                // offline: the cached or bundled elements stay in use
            }
        }
    }

    private func publish(_ comets: [Comet]) {
        DispatchQueue.main.async { self.onComets?(comets) }
    }
}
