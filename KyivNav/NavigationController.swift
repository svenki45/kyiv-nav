import Foundation
import CoreLocation
import UIKit
import NavCore

struct Destination {
    var name: String
    var coord: Coord
}

enum NavPhase {
    case browsing
    case preview
    case navigating
    case arrived
}

enum PositionSource {
    case none
    case gps
    case sensors
}

/// Ведёт по маршруту: берёт положение с GPS, а когда GPS ненадёжен или пропал —
/// «едет» по маршруту сам (скорость, повороты по гироскопу, остановки по вибрации).
final class NavigationController: ObservableObject {
    @Published var phase: NavPhase = .browsing
    @Published var destination: Destination?
    @Published var route: Route?
    @Published var isRouting = false
    @Published var routeError: String?
    @Published var vehicle: Coord?
    @Published var vehicleBearing: Double = 0
    @Published var vehicleAccuracy: Double = 0
    @Published var source: PositionSource = .none
    @Published var track: TrackState?
    @Published var speedMS: Double = 0
    @Published var notice: String?

    var engine: MapEngine?
    let hub: SensorHub
    let settings: AppSettings
    let speaker = Speaker()

    private var tracker: RouteTracker?
    private var dr: DeadReckoner?
    private var free: FreeReckoner?
    private var turns = TurnDetector()
    private var yawAccum = 0.0
    private var smoothSpeed = 0.0
    private var lastCourse = 0.0
    private var offRouteCount = 0
    private var trustedStreak = 0
    private var rerouting = false
    private var spoken: Set<String> = []
    private var timer: Timer?
    private var lastTick = Date()
    private var lastFreeSnap = Date()
    private var motionAvg = 0.0
    private var noticeToken = 0

    init(hub: SensorHub, settings: AppSettings) {
        self.hub = hub
        self.settings = settings
        hub.onFix = { [weak self] loc, ok in self?.handleFix(loc, trusted: ok) }
        hub.onYaw = { [weak self] dt, rate in self?.handleYaw(dt: dt, rate: rate) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: - Сообщения

    private func showNotice(_ text: String, seconds: Double = 5) {
        notice = text
        noticeToken += 1
        let token = noticeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.noticeToken == token { self?.notice = nil }
        }
    }

    // MARK: - Маршрут

    func setDestination(name: String, coord: Coord) {
        guard let e = engine else {
            routeError = "Карта не завантажена"
            return
        }
        let start: Coord? = vehicle ?? hub.coordinate.map { Coord(lat: $0.latitude, lon: $0.longitude) }
        destination = Destination(name: name, coord: coord)
        route = nil
        routeError = nil
        guard let from = start else {
            routeError = "Ще немає положення. Дочекайтесь GPS."
            phase = .browsing
            return
        }
        isRouting = true
        let heading = vehicleBearing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = e.router.route(from: from, to: coord, startHeading: heading)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRouting = false
                guard self.destination?.coord == coord else { return }
                if let r = r {
                    self.route = r
                    self.phase = .preview
                } else {
                    self.routeError = "Маршрут не знайдено: поруч немає дороги або точка недосяжна."
                    self.phase = .browsing
                }
            }
        }
    }

    func startNavigation() {
        guard let r = route else { return }
        tracker = RouteTracker(route: r)
        dr = DeadReckoner(distance: 0, speed: smoothSpeed, total: tracker!.totalLength)
        spoken = []
        offRouteCount = 0
        phase = .navigating
        speaker.enabled = settings.voiceOn
        if settings.keepAwake { UIApplication.shared.isIdleTimerDisabled = true }
        speaker.speak("Маршрут побудовано. \(Format.distanceSpoken(r.distanceM)), приблизно \(Format.duration(r.timeS)).")
        if let v = vehicle { applyPosition(v) }
    }

    func stop() {
        phase = .browsing
        destination = nil
        route = nil
        tracker = nil
        dr = nil
        track = nil
        routeError = nil
        spoken = []
        UIApplication.shared.isIdleTimerDisabled = false
        speaker.stop()
    }

    private func reroute() {
        guard !rerouting, let e = engine, let dest = destination, let v = vehicle else { return }
        rerouting = true
        showNotice("Перебудовую маршрут…", seconds: 8)
        let heading = vehicleBearing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = e.router.route(from: v, to: dest.coord, startHeading: heading)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.rerouting = false
                if self.phase != .navigating { return }
                if let r = r {
                    self.route = r
                    self.tracker = RouteTracker(route: r)
                    self.dr = DeadReckoner(distance: 0, speed: self.smoothSpeed, total: self.tracker!.totalLength)
                    self.spoken = []
                    self.offRouteCount = 0
                    self.showNotice("Маршрут перебудовано")
                    self.speaker.speak("Маршрут перебудовано.")
                    self.applyPosition(v)
                } else {
                    self.showNotice("Не вдалося перебудувати маршрут", seconds: 6)
                    self.offRouteCount = 0
                }
            }
        }
    }

    // MARK: - GPS

    private func handleFix(_ loc: CLLocation, trusted: Bool) {
        if !trusted {
            trustedStreak = 0
            return
        }
        trustedStreak += 1
        let c = Coord(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        let sp = max(loc.speed, 0)
        smoothSpeed = smoothSpeed == 0 ? sp : (smoothSpeed * 0.7 + sp * 0.3)
        if sp < 0.5 { smoothSpeed = min(smoothSpeed, sp + 0.5) }
        if loc.course >= 0 && sp > 2 { lastCourse = loc.course }

        if source == .sensors {
            // после «слепой» езды не верим GPS сразу
            if trustedStreak < 5 { return }
            if phase == .navigating, let tr = tracker, let d = dr {
                let expected = tr.point(atDistance: d.distance).0
                if Geo.distance(expected, c) > 800 && trustedStreak < 20 {
                    showNotice("GPS повернувся, але показує інше місце — вірю датчикам", seconds: 4)
                    return
                }
            }
        }
        vehicleAccuracy = max(loc.horizontalAccuracy, 0)
        speedMS = sp
        applyPosition(c, course: loc.course, speed: sp)
    }

    private func applyPosition(_ c: Coord, course: Double = -1, speed: Double = 0) {
        if phase == .navigating, let tr = tracker {
            let st = tr.update(position: c, searchAll: offRouteCount > 2)
            let tolerance = max(35.0, vehicleAccuracy * 1.5)
            if st.crossTrack < tolerance {
                vehicle = st.snapped
                vehicleBearing = st.bearing
                offRouteCount = 0
            } else {
                vehicle = c
                if course >= 0 && speed > 2 { vehicleBearing = course }
                offRouteCount += 1
            }
            track = st
            dr = DeadReckoner(distance: st.distanceAlong, speed: smoothSpeed, total: tr.totalLength)
            source = .gps
            if offRouteCount >= 4 { reroute() }
            announce(st)
            checkArrival(st)
        } else {
            vehicle = c
            if course >= 0 && speed > 2 { vehicleBearing = course }
            source = .gps
            free = FreeReckoner(position: c, heading: vehicleBearing, speed: smoothSpeed)
        }
    }

    // MARK: - Датчики

    private func handleYaw(dt: Double, rate: Double) {
        yawAccum += rate * dt
        if let angle = turns.feed(dt: dt, rate: rate) {
            handleTurn(angle)
        }
    }

    private func handleTurn(_ angle: Double) {
        guard phase == .navigating, source == .sensors, let r = route, var d = dr else { return }
        if d.sync(turnAngle: angle, maneuvers: r.maneuvers) != nil {
            dr = d
            showNotice("Звірився за поворотом", seconds: 3)
        }
    }

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 2.0)
        lastTick = now
        let yaw = yawAccum / max(dt, 0.001)
        yawAccum = 0
        motionAvg = motionAvg * 0.85 + hub.motionG * 0.15

        let needSensors = hub.state.needsSensors || hub.forceSensors
        if !needSensors || !settings.deadReckoning { return }

        // скорость: последняя хорошая, а если её не было — средняя по маршруту
        var speed = smoothSpeed
        if speed < 2, let r = route, r.timeS > 0 { speed = r.distanceM / r.timeS }
        let moving = motionAvg > 0.012 || speed < 0.1
        if !moving { speed = 0 }

        if phase == .navigating, let tr = tracker, var d = dr {
            d.speed = speed
            d.advance(dt: dt)
            dr = d
            let (p, b) = tr.point(atDistance: d.distance)
            let st = tr.update(position: p)
            vehicle = p
            vehicleBearing = b
            vehicleAccuracy = 40
            speedMS = speed
            track = st
            source = .sensors
            announce(st)
            checkArrival(st)
        } else if var f = free {
            f.speed = speed
            f.step(dt: dt, yawRate: yaw)
            if now.timeIntervalSince(lastFreeSnap) > 2, let e = engine {
                f.snap(router: e.router)
                lastFreeSnap = now
            }
            free = f
            vehicle = f.position
            vehicleBearing = f.heading
            vehicleAccuracy = 50
            speedMS = speed
            source = .sensors
        }
    }

    // MARK: - Голос и прибытие

    private func announce(_ st: TrackState) {
        guard let r = route, st.nextManeuver < r.maneuvers.count else { return }
        let i = st.nextManeuver
        let m = r.maneuvers[i]
        if m.kind == .arrive { return }
        let d = st.distanceToNext
        let thresholds: [Double] = [800, 300, 100]
        // самый близкий порог, который уже пройден
        var kBest = -1
        for (k, th) in thresholds.enumerated() where d <= th { kBest = k }
        if kBest >= 0 && !spoken.contains("\(i)-\(kBest)") {
            for j in 0...kBest { spoken.insert("\(i)-\(j)") }
            speaker.speak(thresholds[kBest] <= 100 ? m.text : m.spoken(distance: d))
        }
    }

    private func checkArrival(_ st: TrackState) {
        if st.remaining < 30 && phase == .navigating {
            phase = .arrived
            speaker.speak("Ви прибули.")
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
