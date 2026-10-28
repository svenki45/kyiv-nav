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
        case .waiting: return "Жду GPS…"
        case .ok: return "GPS в порядке"
        case .poor: return "GPS ненадёжен"
        case .lost: return "GPS пропал"
        }
    }

    var detail: String {
        switch self {
        case .poor(let why): return why
        case .lost: return "Нет новых данных больше 5 секунд"
        default: return ""
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
    @Published var motionG: Double = 0       // сила тряски/ускорения
    @Published var turnRate: Double = 0      // скорость поворота (град/с)
    @Published var state: GPSState = .waiting
    @Published var jumpCount: Int = 0
    @Published var logRows: Int = 0

    private let location = CLLocationManager()
    private let motion = CMMotionManager()

    private var lastFix: CLLocation?
    private var lastFixTime: Date?
    private var timer: Timer?

    private(set) var logURL: URL

    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = Self.fileStamp()
        logURL = docs.appendingPathComponent("gps_log_\(stamp).csv")
        super.init()

        let header = "time,lat,lon,gps_speed_kmh,accuracy_m,heading_deg,accel_g,turn_deg_s,state\n"
        try? header.write(to: logURL, atomically: true, encoding: .utf8)

        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.allowsBackgroundLocationUpdates = true
        location.pausesLocationUpdatesAutomatically = false
        location.headingFilter = 2
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            location.startUpdatingHeading()
        }

        startMotion()

        // Раз в секунду проверяем, не пропал ли GPS, и пишем строку в лог.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: - Датчики движения

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let d = data else { return }
            let a = d.userAcceleration
            self.motionG = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            // Поворот вокруг вертикальной оси (рад/с -> град/с)
            let g = d.gravity
            let r = d.rotationRate
            let vertical = r.x * g.x + r.y * g.y + r.z * g.z
            self.turnRate = vertical * 180 / .pi
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }

        var problem: String?

        if fix.horizontalAccuracy < 0 {
            problem = "Нет точного положения"
        } else if fix.horizontalAccuracy > 100 {
            problem = "Очень низкая точность: \(Int(fix.horizontalAccuracy)) м"
        }

        if let prev = lastFix {
            let dt = fix.timestamp.timeIntervalSince(prev.timestamp)
            if dt > 0.2 {
                let dist = fix.distance(from: prev)
                let implied = dist / dt          // м/с
                if implied > 70 && dist > 100 {  // больше ~250 км/ч — так не бывает
                    problem = "Скачок положения: \(Int(dist)) м за \(Int(dt)) с"
                    jumpCount += 1
                }
            }
        }

        lastFix = fix
        lastFixTime = Date()
        coordinate = fix.coordinate
        accuracyM = max(fix.horizontalAccuracy, 0)
        speedKmh = max(fix.speed, 0) * 3.6
        state = problem.map { GPSState.poor($0) } ?? .ok
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        headingDeg = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ошибки GPS показываем как «ненадёжен», лог продолжаем.
        state = .poor("Ошибка GPS: \(error.localizedDescription)")
    }

    // MARK: - Раз в секунду

    private func tick() {
        if let t = lastFixTime, Date().timeIntervalSince(t) > 5 {
            state = .lost
        }
        writeLogRow()
    }

    private func writeLogRow() {
        let c = coordinate
        let stateName: String
        switch state {
        case .waiting: stateName = "waiting"
        case .ok: stateName = "ok"
        case .poor: stateName = "poor"
        case .lost: stateName = "lost"
        }
        let row = [
            Self.isoTime(Date()),
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
