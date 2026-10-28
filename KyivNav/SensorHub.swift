import Foundation
import CoreLocation
import CoreMotion

/// Состояние GPS для показа на экране.
enum GPSState {
    case waiting          // ещё нет данных
    case ok               // всё нормально
    case poor(String)     // сигнал есть, но ему нельзя доверять
    case lost             // сигнал пропал

    var title: String {
        switch self {
        case .waiting: return "Чекаю GPS…"
        case .ok: return "GPS в порядку"
        case .poor: return "GPS ненадійний"
        case .lost: return "GPS зник"
        }
    }

    var detail: String {
        switch self {
        case .poor(let why): return why
        case .lost: return "Немає нових даних більше 5 секунд"
        default: return ""
        }
    }

    var isTrusted: Bool {
        if case .ok = self { return true }
        return false
    }

    var needsSensors: Bool {
        switch self {
        case .poor, .lost: return true
        default: return false
        }
    }
}

/// Собирает GPS, компас и датчики движения, сравнивает их и пишет лог.
final class SensorHub: NSObject, ObservableObject, CLLocationManagerDelegate {

    // Показ на экране
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var speedKmh: Double = 0
    @Published var accuracyM: Double = 0
    @Published var headingDeg: Double = 0
    @Published var courseDeg: Double = -1
    @Published var motionG: Double = 0
    @Published var turnRate: Double = 0
    @Published var state: GPSState = .waiting
    @Published var jumpCount: Int = 0
    @Published var logRows: Int = 0
    /// Пользователь велел не верить GPS (режим «только датчики»)
    @Published var forceSensors: Bool = false

    /// Новая точка GPS: (точка, можно ли ей верить)
    var onFix: ((CLLocation, Bool) -> Void)?
    /// Датчик вращения, 10 раз в секунду: (секунды, градусы в секунду, плюс — вправо)
    var onYaw: ((Double, Double) -> Void)?
    var saveLog: Bool = true

    private let location = CLLocationManager()
    private let motion = CMMotionManager()

    private var lastFix: CLLocation?
    private var lastFixTime: Date?
    private var lastMotionStamp: TimeInterval?
    private var timer: Timer?

    private(set) var logURL: URL

    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logURL = docs.appendingPathComponent("gps_log_\(SensorHub.fileStamp()).csv")
        super.init()

        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.activityType = .automotiveNavigation
        location.allowsBackgroundLocationUpdates = true
        location.pausesLocationUpdatesAutomatically = false
        location.headingFilter = 2
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            location.startUpdatingHeading()
        }

        startMotion()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Файл лога для отправки (создаёт, если ещё нет).
    func logFileForSharing() -> URL {
        ensureLogFile()
        return logURL
    }

    /// Файл лога создаётся при первой записи, чтобы не плодить пустые файлы.
    private func ensureLogFile() {
        if FileManager.default.fileExists(atPath: logURL.path) { return }
        let header = "time,lat,lon,gps_speed_kmh,accuracy_m,heading_deg,accel_g,turn_deg_s,state\n"
        try? header.write(to: logURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Датчики движения

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let d = data else { return }
            let a = d.userAcceleration
            self.motionG = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            // Поворот вокруг вертикальной оси (рад/с -> град/с), плюс — вправо
            let g = d.gravity
            let r = d.rotationRate
            let vertical = r.x * g.x + r.y * g.y + r.z * g.z
            self.turnRate = vertical * 180 / .pi
            var dt = 0.1
            if let last = self.lastMotionStamp {
                dt = min(max(d.timestamp - last, 0.001), 0.5)
            }
            self.lastMotionStamp = d.timestamp
            self.onYaw?(dt, self.turnRate)
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }

        var problem: String?

        if fix.horizontalAccuracy < 0 {
            problem = "Немає точного положення"
        } else if fix.horizontalAccuracy > 100 {
            problem = "Дуже низька точність: \(Int(fix.horizontalAccuracy)) м"
        }

        if let prev = lastFix {
            let dt = fix.timestamp.timeIntervalSince(prev.timestamp)
            if dt > 0.2 {
                let dist = fix.distance(from: prev)
                let implied = dist / dt          // м/с
                if implied > 70 && dist > 100 {  // понад ~250 км/год — так не буває
                    problem = "Стрибок положення: \(Int(dist)) м за \(Int(dt)) с"
                    jumpCount += 1
                }
            }
        }

        if forceSensors { problem = "Режим «тільки датчики»" }

        lastFix = fix
        lastFixTime = Date()
        coordinate = fix.coordinate
        accuracyM = max(fix.horizontalAccuracy, 0)
        speedKmh = max(fix.speed, 0) * 3.6
        courseDeg = fix.course
        state = problem.map { GPSState.poor($0) } ?? .ok
        onFix?(fix, problem == nil)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        headingDeg = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        state = .poor("Помилка GPS: \(error.localizedDescription)")
    }

    // MARK: - Раз в секунду

    private func tick() {
        if let t = lastFixTime, Date().timeIntervalSince(t) > 5 {
            state = .lost
        }
        if forceSensors, case .ok = state {
            state = .poor("Режим «тільки датчики»")
        }
        writeLogRow()
    }

    private func writeLogRow() {
        if !saveLog { return }
        ensureLogFile()
        let c = coordinate
        let stateName: String
        switch state {
        case .waiting: stateName = "waiting"
        case .ok: stateName = "ok"
        case .poor: stateName = "poor"
        case .lost: stateName = "lost"
        }
        let row = [
            SensorHub.isoTime(Date()),
            c.map { String(format: "%.6f", $0.latitude) } ?? "",
            c.map { String(format: "%.6f", $0.longitude) } ?? "",
            String(format: "%.1f", speedKmh),
            String(format: "%.0f", accuracyM),
            String(format: "%.0f", headingDeg),
            String(format: "%.3f", motionG),
            String(format: "%.1f", turnRate),
            stateName
        ].joined(separator: ",") + "\n"

        if let h = try? FileHandle(forWritingTo: logURL), let data = row.data(using: .utf8) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
            logRows += 1
        }
    }

    // MARK: - Вспомогательное

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    private static func isoTime(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }
}
