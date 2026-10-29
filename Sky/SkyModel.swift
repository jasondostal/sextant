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
    /// Time travel: how far the sky runs ahead of (or behind) the clock. It keeps ticking.
    var timeOffset: TimeInterval = 0
    var timeBarOpen = UserDefaults.standard.bool(forKey: "timebar")
    var timeUnit: TimeUnit = .hour

    @ObservationIgnored private var bodyCache: (Date, Observer, [BodyPosition])?
    @ObservationIgnored private let locator = Locator()
    @ObservationIgnored private let motion = MotionTracker()
    @ObservationIgnored let satellites = SatelliteTracker()
    @ObservationIgnored private let feed = SatelliteFeed()
    /// When the satellite orbits in use were downloaded; nil until there are any.
    var satellitesFetched: Date?
    var satelliteCount = 0

    var pointing: Bool { camera.attitude != nil }

    /// What search picked; ringed on the sky, arrowed when off screen.
    var target: Target?
    /// While set (drag mode), the camera keeps the target centred; a drag lets go.
    @ObservationIgnored private var following = false
    @ObservationIgnored private var flight: (from: Camera, start: Date)?
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
        feed.onCatalog = { [weak self] cat, at in
            guard let self else { return }
            self.satellites.setCatalog(cat)
            self.satellitesFetched = at
            self.satelliteCount = cat.satellites.count
            self.applySelectArgument()
        }
        feed.start()
        // phone out, already pointing: the moving dot won't wait for a mode switch
        if motion.available, UserDefaults.standard.bool(forKey: "pointMode") { setPointing(true) }
    }

    var now: Date { date(at: Date()) }

    /// The sky's time when the wall clock reads `wall`.
    func date(at wall: Date) -> Date { fixedDate ?? wall.addingTimeInterval(timeOffset) }

    var timeTraveling: Bool { fixedDate != nil || timeOffset != 0 }

    func shiftTime(by s: TimeInterval) {
        if let d = fixedDate { fixedDate = d.addingTimeInterval(s) } else { timeOffset += s }
    }

    /// Calendar days, so the clock time stays put across a daylight-saving change.
    func shiftDays(_ n: Int) {
        let t = now
        guard let later = Calendar.current.date(byAdding: .day, value: n, to: t) else { return }
        shiftTime(by: later.timeIntervalSince(t))
    }

    func resetTime() {
        fixedDate = nil
        timeOffset = 0
    }

    /// Orbits are good for a week or two either side of their epoch; past that
    /// the satellites would be drawn in made-up places.
    func satellitesValid(at date: Date) -> Bool {
        guard let at = satellitesFetched else { return false }
        return abs(date.timeIntervalSince(at)) < 14 * 86400
    }

    func frame(at date: Date) -> SkyFrame { SkyFrame(date: date, observer: observer) }

    /// Sun, Moon and planets, recomputed at most once a second.
    func bodies(at date: Date) -> [BodyPosition] {
        if let (t, o, b) = bodyCache, o == observer, abs(t.timeIntervalSince(date)) < 1 { return b }
        let f = frame(at: date)
        let b = Body.allCases.map { f.position(of: $0) }
        bodyCache = (date, observer, b)
        return b
    }

    /// Faintest star drawn: deeper as you zoom in, like binoculars.
    func starLimit(fov: Double) -> Double { min(8.0, 6.3 + 2.0 * log10(max(1, 75 / fov))) }

    /// Satellites you could actually see: up, sunlit, against a darkening sky,
    /// and bright enough for the zoom.
    func visibleSatellites(at date: Date) -> [SatelliteTracker.Visible] {
        guard let sun = bodies(at: date).first(where: { $0.body == .sun }),
              sun.geometric.altitude < -3, satellitesValid(at: date) else { return [] }
        let limit = min(7.5, starLimit(fov: camera.fov) - 1.0)
        return satellites.positions(at: date, observer: observer)
            .filter { $0.position.sunlit && $0.position.magnitude <= limit }
            .sorted { $0.position.magnitude < $1.position.magnitude }
    }

    // MARK: point mode and gestures

    func setPointing(_ on: Bool) {
        if motion.available { UserDefaults.standard.set(on, forKey: "pointMode") }
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

    /// `fly`: centre the view on it and follow (search); a tap just rings it where it is.
    func select(_ t: Target, fly: Bool = true) {
        target = t
        following = fly
        flight = fly ? (camera, Date()) : nil
    }

    func clearTarget() {
        target = nil
        following = false
        flight = nil
    }

    /// Called once per drawn frame: flies toward, then follows, the target.
    func tick(_ date: Date) {
        guard following, !pointing, let t = target, let r = resolve(t, at: date) else { return }
        let dest = r.horizontal
        guard let (from, start) = flight else {
            camera.azimuth = dest.azimuth
            camera.altitude = max(-89, min(89, dest.altitude))
            return
        }
        let u = min(1, Date().timeIntervalSince(start) / 0.9)
        let e = u * u * (3 - 2 * u)                               // smoothstep
        let dAz = remainder(dest.azimuth - from.azimuth, 360)     // the short way round
        var az = (from.azimuth + dAz * e).truncatingRemainder(dividingBy: 360)
        if az < 0 { az += 360 }
        camera.azimuth = az
        camera.altitude = max(-89, min(89, from.altitude + (dest.altitude - from.altitude) * e))
        if u >= 1 { flight = nil }
    }

    func pan(dx: Double, dy: Double, perDegree: Double) {
        guard !pointing else { return }
        if dx != 0 || dy != 0 {
            following = false
            flight = nil
        }
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

    /// `-select Jupiter` picks the first search result (satellites once their data loads).
    private func applySelectArgument() {
        guard target == nil, let q = UserDefaults.standard.string(forKey: "select"),
              let t = search(q).first, let r = resolve(t, at: now) else { return }
        // only a name that starts with it: "ISS" mustn't settle for Meissa before the satellites load
        if case .satellite = t {} else if !r.name.lowercased().hasPrefix(q.lowercased()) { return }
        select(t)
    }

    /// `-az 270 -alt 30 -fov 80 -time 2026-10-29T02:00:00Z -lat 44.52 -lon -89.57`
    /// (`-offsetHours 8.5` runs live but shifted; `-timebar YES` opens time travel;
    /// `-frozenPoint YES` draws point mode held still at -az/-alt)
    private func applyLaunchArguments() {
        let d = UserDefaults.standard
        if d.object(forKey: "az") != nil { camera.azimuth = d.double(forKey: "az") }
        if d.object(forKey: "alt") != nil { camera.altitude = d.double(forKey: "alt") }
        if d.object(forKey: "fov") != nil { camera.fov = d.double(forKey: "fov") }
        // pretend the phone is held still at -az/-alt: point mode's look without the sensors
        if d.bool(forKey: "frozenPoint") {
            let b = camera.basis
            camera.attitude = Camera.Basis(right: b.right, up: b.up, forward: b.forward)
        }
        if let t = d.string(forKey: "time"), let date = ISO8601DateFormatter().date(from: t) { fixedDate = date }
        if d.object(forKey: "offsetHours") != nil { timeOffset = d.double(forKey: "offsetHours") * 3600 }
        applySelectArgument()
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
