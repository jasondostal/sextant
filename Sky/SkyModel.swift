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
    var observer: Observer
    var location: LocationSource
    /// Nil = live; otherwise the sky is frozen at this instant.
    var fixedDate: Date?
    /// Time travel: how far the sky runs ahead of (or behind) the clock. It keeps ticking.
    var timeOffset: TimeInterval = 0
    var timeBarOpen = UserDefaults.standard.bool(forKey: "timebar")
    var timeUnit: TimeUnit = .hour
    /// Constellation figures: just the one you're looking at (Star Walk's way), all, or none.
    enum LineMode: String, CaseIterable { case auto = "Auto", always = "Always", never = "Never" }
    var lineMode = LineMode(rawValue: UserDefaults.standard.string(forKey: "lineMode") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(lineMode.rawValue, forKey: "lineMode") }
    }
    var showEcliptic = UserDefaults.standard.object(forKey: "ecliptic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showEcliptic, forKey: "ecliptic") }
    }
    /// How solid the land is: eased toward almost nothing while you look down
    /// at a target below the horizon, so you can see it through the Earth.
    @ObservationIgnored var groundAlpha: Float = 1
    /// Everything in dim red, to keep eyes dark-adapted; remembered.
    var nightMode = UserDefaults.standard.bool(forKey: "nightMode") {
        didSet { UserDefaults.standard.set(nightMode, forKey: "nightMode") }
    }

    /// How much deeper (or shallower) than the default the faintest stars go; Settings.
    var magOffset = UserDefaults.standard.double(forKey: "magOffset") {
        didSet { UserDefaults.standard.set(magOffset, forKey: "magOffset") }
    }
    static let magOffsetRange = -2.0...1.5

    // search: the query survives closing the panel, so "‹ Search" comes back to it
    var searchQuery = UserDefaults.standard.string(forKey: "search") ?? ""
    /// Set when the target came from search; shows the way back to the results.
    var searchReturn = false
    var recents: [Target] = SkyModel.loadRecents()
    @ObservationIgnored let hints = HintCache()

    /// Comets forecast brighter than 12 within the year: the bundled snapshot, then the MPC's.
    var comets: [Comet] = SkyModel.keepComets(CometCatalog.bundled, around: Date())
    @ObservationIgnored private let cometFeed = CometFeed()
    @ObservationIgnored private var cometCache: (Date, Observer, [CometPosition])?

    @ObservationIgnored private var bodyCache: (Date, Observer, [BodyPosition])?
    @ObservationIgnored private let locator = Locator()
    @ObservationIgnored private let motion = MotionTracker()
    @ObservationIgnored let satellites = SatelliteTracker()
    @ObservationIgnored private let feed = SatelliteFeed()
    /// When the satellite orbits in use were downloaded; nil until there are any.
    var satellitesFetched: Date?
    var satelliteCount = 0

    var pointing: Bool { camera.attitude != nil }
    static let pointFOV = 88.0

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
        (observer, location) = Self.timeZoneGuess()
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
        cometFeed.onComets = { [weak self] all in
            guard let self else { return }
            Task.detached(priority: .utility) {
                let kept = Self.keepComets(all, around: Date())
                await MainActor.run {
                    self.comets = kept
                    self.cometCache = nil
                }
            }
        }
        cometFeed.start()
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

    /// Every carried comet's position, recomputed at most once a second.
    func cometPositions(at date: Date) -> [CometPosition] {
        if let (t, o, c) = cometCache, o == observer, abs(t.timeIntervalSince(date)) < 1 { return c }
        let f = frame(at: date)
        let c = comets.map { f.position(of: $0) }
        cometCache = (date, observer, c)
        return c
    }

    /// Faintest star drawn: deeper as you zoom in, like binoculars.
    func starLimit(fov: Double) -> Double { min(8.0, 6.3 + magOffset + 2.0 * log10(max(1, 75 / fov))) }

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
            // a wider window when you hold the phone up (Star Walk's is ~88°), unless zoomed in on purpose
            if camera.fov >= 60 { camera.fov = Self.pointFOV }
            motion.onUpdate = { [weak self] b in self?.camera.attitude = b }
            motion.fov = { [weak self] in self?.camera.fov ?? 75 }
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
        searchReturn = false
        following = fly
        flight = fly ? (camera, Date()) : nil
    }

    func clearTarget() {
        target = nil
        searchReturn = false
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
        // `-searchReturn YES`: as if it came from search (the "‹ Search" pill)
        if UserDefaults.standard.bool(forKey: "searchReturn") { searchReturn = true }
    }

    /// `-az 270 -alt 30 -fov 80 -time 2026-10-29T02:00:00Z -lat 44.52 -lon -89.57`
    /// (`-offsetHours 8.5` runs live but shifted; `-timebar YES` opens time travel;
    /// `-frozenPoint YES` draws point mode held still at -az/-alt)
    private func applyLaunchArguments() {
        let d = UserDefaults.standard
        if let v = Self.launchDouble("az") { camera.azimuth = v }
        if let v = Self.launchDouble("alt") { camera.altitude = v }
        if let v = Self.launchDouble("fov") { camera.fov = v }
        // pretend the phone is held still at -az/-alt: point mode's look without the sensors
        if d.bool(forKey: "frozenPoint") {
            let b = camera.basis
            camera.attitude = Camera.Basis(right: b.right, up: b.up, forward: b.forward)
        }
        if let t = d.string(forKey: "time"), let date = ISO8601DateFormatter().date(from: t) { fixedDate = date }
        if let v = Self.launchDouble("offsetHours") { timeOffset = v * 3600 }
        applySelectArgument()
        if let lat = Self.launchDouble("lat"), let lon = Self.launchDouble("lon") {
            observer = Observer(latitude: lat, longitude: lon, height: Self.launchDouble("height") ?? 0)
            location = .fallback(d.string(forKey: "place") ?? "set by launch arguments")
            argumentsSetPlace = true
        }
    }

    /// A numeric launch argument. Read from the command line itself, because the
    /// defaults system takes `-lon -89.57` for two flags and drops the negative value.
    static func launchDouble(_ key: String) -> Double? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-" + key), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
        return UserDefaults.standard.object(forKey: key) != nil ? UserDefaults.standard.double(forKey: key) : nil
    }
}

extension SkyModel {
    /// Until (or unless) there's a GPS fix: the principal city of the phone's time
    /// zone (IANA zone.tab, bundled). Hundreds of km off at worst, which moves the
    /// stars by a few degrees, against a whole hemisphere for a fixed default.
    static func timeZoneGuess() -> (Observer, LocationSource) {
        if let url = Bundle.main.url(forResource: "zones", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let zones = try? JSONSerialization.jsonObject(with: data) as? [String: [Any]],
           let z = zones[TimeZone.current.identifier],
           let lat = z[0] as? Double, let lon = z[1] as? Double, let city = z[2] as? String {
            return (Observer(latitude: lat, longitude: lon, height: 0), .fallback(city))
        }
        return (Observer(latitude: 0, longitude: 0, height: 0), .fallback("0°, 0°"))
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
