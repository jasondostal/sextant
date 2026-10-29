import CoreLocation
import Foundation
import Observation
import simd
import SkyCore

/// Everything the sky view shows, and where its observer stands.
@Observable
final class SkyModel {
    let sky: SkyData
    var camera = Camera()
    var observer = Observer(latitude: 44.5236, longitude: -89.5746, height: 330)
    var location: LocationSource = .fallback("Stevens Point")
    /// Nil = live; otherwise the sky is frozen at this instant.
    var fixedDate: Date?

    @ObservationIgnored private var bodyCache: (Date, Observer, [BodyPosition])?
    @ObservationIgnored private let locator = Locator()
    @ObservationIgnored private let motion = MotionTracker()

    var pointing: Bool { camera.attitude != nil }
    var canPoint: Bool { motion.available }

    enum LocationSource: Equatable {
        case fallback(String)
        case gps(Date)
    }

    init() {
        sky = try! SkyData.load()
        applyLaunchArguments()
        locator.onFix = { [weak self] loc in
            guard let self else { return }
            self.observer = Observer(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
                                     height: max(loc.altitude, 0))
            self.location = .gps(loc.timestamp)
        }
        if !argumentsSetPlace { locator.start() }
    }

    var now: Date { fixedDate ?? Date() }

    func frame(at date: Date) -> SkyFrame { SkyFrame(date: date, observer: observer) }

    /// Sun, Moon and planets, recomputed at most once a second.
    func bodies(at date: Date) -> [BodyPosition] {
        if let (t, o, b) = bodyCache, o == observer, abs(t.timeIntervalSince(date)) < 1 { return b }
        let f = frame(at: date)
        let b = Body.allCases.map { f.position(of: $0) }
        bodyCache = (date, observer, b)
        return b
    }

    // MARK: point mode and gestures

    func setPointing(_ on: Bool) {
        if on {
            motion.onUpdate = { [weak self] b in self?.camera.attitude = b }
            motion.start()
        } else {
            motion.stop()
            // keep looking where the phone was pointing
            if let f = camera.attitude?.forward {
                let h = Horizontal(vector: SIMD3<Double>(f))
                camera.azimuth = h.azimuth
                camera.altitude = h.altitude
            }
            camera.attitude = nil
        }
    }

    func pan(dx: Double, dy: Double, perDegree: Double) {
        guard !pointing else { return }
        // the sky follows the finger
        camera.azimuth = (camera.azimuth - dx / perDegree).truncatingRemainder(dividingBy: 360)
        if camera.azimuth < 0 { camera.azimuth += 360 }
        camera.altitude = min(90, max(-30, camera.altitude + dy / perDegree))
    }

    func zoom(by factor: Double) {
        camera.fov = min(Camera.fovRange.upperBound, max(Camera.fovRange.lowerBound, camera.fov / factor))
    }

    // MARK: deterministic views for screenshots and oracle comparisons

    @ObservationIgnored private var argumentsSetPlace = false

    /// `-az 270 -alt 30 -fov 80 -time 2026-10-29T02:00:00Z -lat 44.52 -lon -89.57`
    private func applyLaunchArguments() {
        let d = UserDefaults.standard
        if d.object(forKey: "az") != nil { camera.azimuth = d.double(forKey: "az") }
        if d.object(forKey: "alt") != nil { camera.altitude = d.double(forKey: "alt") }
        if d.object(forKey: "fov") != nil { camera.fov = d.double(forKey: "fov") }
        if let t = d.string(forKey: "time"), let date = ISO8601DateFormatter().date(from: t) { fixedDate = date }
        if d.object(forKey: "lat") != nil, d.object(forKey: "lon") != nil {
            observer = Observer(latitude: d.double(forKey: "lat"), longitude: d.double(forKey: "lon"),
                                height: d.double(forKey: "height"))
            location = .fallback(d.string(forKey: "place") ?? "set by launch arguments")
            argumentsSetPlace = true
        }
    }
}

/// One-shot-ish GPS: the sky doesn't care about a few hundred metres, so a
/// coarse fix every few minutes is plenty.
final class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onFix: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 500
    }

    func start() {
        #if os(iOS)
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        #endif
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async { self.onFix?(loc) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        #if os(iOS)
        if manager.authorizationStatus == .authorizedWhenInUse { manager.startUpdatingLocation() }
        #endif
    }
}
