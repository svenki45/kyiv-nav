import Foundation

public enum ManeuverKind: String {
    case depart
    case slightLeft, left, sharpLeft
    case slightRight, right, sharpRight
    case uTurn
    case roundabout
    case arrive
}

public struct Maneuver {
    public var kind: ManeuverKind
    /// Индекс точки в Route.coords
    public var coordIndex: Int
    /// Расстояние от начала маршрута (по точкам маршрута), метры
    public var distanceFromStart: Double
    public var streetName: String?
    public var exitNumber: Int?
    /// Угол поворота в градусах (плюс — вправо)
    public var turnAngle: Double
    public var coord: Coord

    public var isLeft: Bool {
        return kind == .left || kind == .slightLeft || kind == .sharpLeft
    }

    public var isRight: Bool {
        return kind == .right || kind == .slightRight || kind == .sharpRight
    }

    /// Короткий текст: что сделать.
    public var action: String {
        switch kind {
        case .depart: return "Рушайте"
        case .slightLeft: return "Тримайтесь ліворуч"
        case .left: return "Поверніть ліворуч"
        case .sharpLeft: return "Різко ліворуч"
        case .slightRight: return "Тримайтесь праворуч"
        case .right: return "Поверніть праворуч"
        case .sharpRight: return "Різко праворуч"
        case .uTurn: return "Розверніться"
        case .roundabout:
            if let n = exitNumber { return "На кільці виїдьте на \(n)-й з'їзд" }
            return "На кільці"
        case .arrive: return "Ви прибули"
        }
    }

    public var text: String {
        if let n = streetName, kind != .arrive {
            return "\(action), \(n)"
        }
        return action
    }

    /// Текст для голоса: «Через 300 метрів, поверніть праворуч».
    public func spoken(distance: Double?) -> String {
        guard let d = distance, d > 30 else { return text }
        return "Через \(Format.distanceSpoken(d)), \(text.prefix(1).lowercased() + text.dropFirst())"
    }
}

public enum Format {
    public static func distance(_ m: Double) -> String {
        if m < 1000 {
            let r = m < 100 ? Int((m / 10).rounded()) * 10 : Int((m / 50).rounded()) * 50
            return "\(r) м"
        }
        let km = m / 1000
        if km < 10 { return String(format: "%.1f км", km).replacingOccurrences(of: ".", with: ",") }
        return "\(Int(km.rounded())) км"
    }

    public static func distanceSpoken(_ m: Double) -> String {
        if m < 1000 {
            let r = m < 100 ? Int((m / 10).rounded()) * 10 : Int((m / 50).rounded()) * 50
            return "\(r) метрів"
        }
        let km = m / 1000
        if km < 10 { return String(format: "%.1f кілометра", km).replacingOccurrences(of: ".", with: ",") }
        return "\(Int(km.rounded())) кілометрів"
    }

    public static func duration(_ s: Double) -> String {
        let mins = Int((s / 60).rounded())
        if mins < 60 { return "\(max(mins, 1)) хв" }
        return "\(mins / 60) г \(mins % 60) хв"
    }
}

public enum Guidance {

    static func cumulative(_ coords: [Coord]) -> [Double] {
        var cum: [Double] = [0]
        cum.reserveCapacity(coords.count)
        var t = 0.0
        if coords.count > 1 {
            for i in 1..<coords.count {
                t += Geo.distance(coords[i - 1], coords[i])
                cum.append(t)
            }
        }
        return cum
    }

    /// Направление в конце участка coords[first...last] (по последним ~15 м).
    static func endBearing(_ coords: [Coord], _ first: Int, _ last: Int) -> Double {
        var j = last
        var acc = 0.0
        while j > first && acc < 15 {
            acc += Geo.distance(coords[j - 1], coords[j])
            j -= 1
        }
        if j == last { return 0 }
        return Geo.bearing(from: coords[j], to: coords[last])
    }

    /// Направление в начале участка (по первым ~15 м).
    static func startBearing(_ coords: [Coord], _ first: Int, _ last: Int) -> Double {
        var j = first
        var acc = 0.0
        while j < last && acc < 15 {
            acc += Geo.distance(coords[j], coords[j + 1])
            j += 1
        }
        if j == first { return 0 }
        return Geo.bearing(from: coords[first], to: coords[j])
    }

    static func hasExit(_ g: GraphData, node: Int) -> Bool {
        let a0 = g.arcStart(node)
        let a1 = g.arcStart(node + 1)
        if a0 >= a1 { return false }
        for k in a0..<a1 {
            let s = Int(g.arc(k) & 0x7FFF_FFFF)
            if !g.segment(s).isRoundabout { return true }
        }
        return false
    }

    public static func maneuvers(route: Route, graph g: GraphData) -> [Maneuver] {
        let coords = route.coords
        let cum = cumulative(coords)
        let legs = route.legs
        var out: [Maneuver] = []
        if coords.isEmpty || legs.isEmpty { return out }

        out.append(Maneuver(kind: .depart, coordIndex: 0, distanceFromStart: 0,
                            streetName: legs[0].name, exitNumber: nil, turnAngle: 0, coord: coords[0]))

        var exitCount = 0
        if legs.count >= 2 {
            for i in 0..<(legs.count - 1) {
                let cur = legs[i]
                let nxt = legs[i + 1]
                let node = cur.endNode
                if node < 0 { continue }

                if !cur.isRoundabout && nxt.isRoundabout {
                    exitCount = 0
                    continue
                }
                if cur.isRoundabout && nxt.isRoundabout {
                    if hasExit(g, node: node) { exitCount += 1 }
                    continue
                }
                if cur.isRoundabout && !nxt.isRoundabout {
                    exitCount += 1
                    let idx = min(cur.lastCoord, coords.count - 1)
                    out.append(Maneuver(kind: .roundabout, coordIndex: idx, distanceFromStart: cum[idx],
                                        streetName: nxt.name, exitNumber: exitCount, turnAngle: 0,
                                        coord: coords[idx]))
                    continue
                }

                // обычный перекрёсток: есть ли выбор?
                var choices = 0
                let a0 = g.arcStart(node)
                let a1 = g.arcStart(node + 1)
                if a0 < a1 {
                    for k in a0..<a1 {
                        let s = Int(g.arc(k) & 0x7FFF_FFFF)
                        if s != cur.segment { choices += 1 }
                    }
                }
                if choices < 2 { continue }

                let inB = endBearing(coords, cur.firstCoord, cur.lastCoord)
                let outB = startBearing(coords, nxt.firstCoord, nxt.lastCoord)
                let delta = Geo.angleDiff(inB, outB)
                let a = abs(delta)
                if a < 25 { continue }
                var kind: ManeuverKind
                if a < 45 { kind = delta > 0 ? .slightRight : .slightLeft }
                else if a < 135 { kind = delta > 0 ? .right : .left }
                else if a < 170 { kind = delta > 0 ? .sharpRight : .sharpLeft }
                else { kind = .uTurn }
                let idx = min(cur.lastCoord, coords.count - 1)
                out.append(Maneuver(kind: kind, coordIndex: idx, distanceFromStart: cum[idx],
                                    streetName: nxt.name, exitNumber: nil, turnAngle: delta,
                                    coord: coords[idx]))
            }
        }
        let last = coords.count - 1
        out.append(Maneuver(kind: .arrive, coordIndex: last, distanceFromStart: cum[last],
                            streetName: nil, exitNumber: nil, turnAngle: 0, coord: coords[last]))
        return out
    }
}

// MARK: - Слежение за маршрутом

public struct TrackState {
    public var distanceAlong: Double
    public var crossTrack: Double
    public var remaining: Double
    public var remainingTime: Double
    public var nextManeuver: Int
    public var distanceToNext: Double
    public var snapped: Coord
    public var bearing: Double
}

public final class RouteTracker {
    public let route: Route
    let cum: [Double]
    let total: Double
    private var lastIndex = 0

    public init(route: Route) {
        self.route = route
        self.cum = Guidance.cumulative(route.coords)
        self.total = cum.last ?? 0
    }

    public var totalLength: Double { return total }

    /// Точка на маршруте по расстоянию от начала и направление движения.
    public func point(atDistance d: Double) -> (Coord, Double) {
        let coords = route.coords
        let dd = min(max(d, 0), total)
        var i = 1
        while i < coords.count - 1 && cum[i] < dd { i += 1 }
        let a = coords[i - 1]
        let b = coords[i]
        let seg = cum[i] - cum[i - 1]
        let t = seg > 0 ? (dd - cum[i - 1]) / seg : 0
        let p = Coord(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
        return (p, Geo.bearing(from: a, to: b))
    }

    public func nextManeuverIndex(after distance: Double) -> Int {
        let ms = route.maneuvers
        for (i, m) in ms.enumerated() where i > 0 && m.distanceFromStart > distance - 8 { return i }
        return max(ms.count - 1, 0)
    }

    /// Привязывает положение к маршруту. Ищет вперёд от прошлого места (или по всему маршруту).
    public func update(position p: Coord, searchAll: Bool = false) -> TrackState {
        let coords = route.coords
        var from = max(lastIndex - 3, 0)
        var to = min(lastIndex + 120, coords.count - 2)
        if searchAll { from = 0; to = coords.count - 2 }
        var best = Double.infinity
        var bestI = max(min(lastIndex, coords.count - 2), 0)
        var bestT = 0.0
        var bestPoint = coords[bestI]
        if from <= to {
            for i in from...to {
                let pr = Geo.project(p, coords[i], coords[i + 1])
                if pr.dist < best {
                    best = pr.dist
                    bestI = i
                    bestT = pr.t
                    bestPoint = pr.point
                }
            }
        }
        lastIndex = bestI
        let along = cum[bestI] + bestT * (cum[bestI + 1] - cum[bestI])
        let nextIdx = nextManeuverIndex(after: along)
        let remaining = max(total - along, 0)
        let ratio = total > 0 ? remaining / total : 0
        return TrackState(distanceAlong: along, crossTrack: best, remaining: remaining,
                          remainingTime: route.timeS * ratio, nextManeuver: nextIdx,
                          distanceToNext: max(route.maneuvers[nextIdx].distanceFromStart - along, 0),
                          snapped: bestPoint,
                          bearing: Geo.bearing(from: coords[bestI], to: coords[bestI + 1]))
    }

    public func reset() { lastIndex = 0 }
}

// MARK: - Датчики: повороты по гироскопу

/// Замечает завершённый поворот по скорости вращения (градусы/с, плюс — вправо).
public struct TurnDetector {
    private var accum = 0.0
    private var inTurn = false
    private var quiet = 0.0
    public var minAngle = 30.0

    public init() {}

    /// Возвращает угол поворота (градусы, плюс — вправо), когда поворот закончился.
    public mutating func feed(dt: Double, rate: Double) -> Double? {
        if abs(rate) > 6 {
            inTurn = true
            accum += rate * dt
            quiet = 0
            return nil
        }
        if inTurn {
            quiet += dt
            if quiet > 1.0 {
                let result = accum
                accum = 0
                inTurn = false
                quiet = 0
                return abs(result) >= minAngle ? result : nil
            }
        }
        return nil
    }

    public mutating func reset() {
        accum = 0
        inTurn = false
        quiet = 0
    }
}

// MARK: - Движение без маршрута и без GPS

/// Едет «вслепую» по последнему направлению и скорости, поворачивает по гироскопу
/// и прижимается к ближайшей подходящей дороге.
public struct FreeReckoner {
    public private(set) var position: Coord
    public private(set) var heading: Double
    public var speed: Double  // м/с

    public init(position: Coord, heading: Double, speed: Double) {
        self.position = position
        self.heading = heading
        self.speed = speed
    }

    public mutating func step(dt: Double, yawRate: Double) {
        var h = (heading + yawRate * dt).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        heading = h
        position = Geo.destination(from: position, bearing: heading, meters: speed * dt)
    }

    /// Прижимает положение к дороге. Возвращает false, если дороги рядом нет.
    @discardableResult
    public mutating func snap(router: Router, maxDistance: Double = 60) -> Bool {
        guard let s = router.snap(position, maxDistance: maxDistance, heading: heading) else { return false }
        position = s.point
        heading = s.travelBearing(near: heading)
        return true
    }
}

// MARK: - Движение по маршруту без GPS

/// Когда GPS пропал, «едет» по маршруту с последней скоростью и подтягивается к ближайшему
/// подходящему повороту, когда гироскоп заметил поворот.
public struct DeadReckoner {
    public private(set) var distance: Double
    public var speed: Double  // м/с
    public let total: Double

    public init(distance: Double, speed: Double, total: Double) {
        self.distance = distance
        self.speed = speed
        self.total = total
    }

    public mutating func advance(dt: Double) {
        distance = min(distance + speed * dt, total)
    }

    public mutating func set(distance d: Double) {
        distance = min(max(d, 0), total)
    }

    /// Подтягивает положение к повороту маршрута. Возвращает номер манёвра, если нашёл.
    @discardableResult
    public mutating func sync(turnAngle: Double, maneuvers: [Maneuver]) -> Int? {
        var bestI: Int? = nil
        var bestScore = Double.infinity
        for (i, m) in maneuvers.enumerated() {
            if m.kind == .depart || m.kind == .arrive || m.kind == .roundabout { continue }
            let sameSide = (turnAngle > 0 && m.turnAngle > 0) || (turnAngle < 0 && m.turnAngle < 0)
            if !sameSide { continue }
            let delta = m.distanceFromStart - distance
            if delta < -120 || delta > 350 { continue }
            let angleMiss = abs(abs(turnAngle) - abs(m.turnAngle))
            if angleMiss > 60 { continue }
            let score = abs(delta) + angleMiss
            if score < bestScore {
                bestScore = score
                bestI = i
            }
        }
        if let i = bestI {
            set(distance: maneuvers[i].distanceFromStart + 8)
        }
        return bestI
    }
}
