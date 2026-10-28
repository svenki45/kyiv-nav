import Foundation

public struct SnapResult {
    public var segment: Int
    /// Метры от начала сегмента (узла u) вдоль дороги.
    public var along: Double
    public var point: Coord
    /// Расстояние от исходной точки до дороги.
    public var distance: Double
    public var segLength: Double
}

public struct RouteLeg {
    public var segment: Int
    public var reversed: Bool
    public var fromAlong: Double
    public var toAlong: Double
    public var lengthM: Double
    public var timeS: Double
    public var name: String?
    public var cls: Int
    public var isRoundabout: Bool
    public var firstCoord: Int
    public var lastCoord: Int
    /// Узел в конце ноги, если нога заканчивается на перекрёстке; иначе -1.
    public var endNode: Int
}

public struct Route {
    public var coords: [Coord]
    public var legs: [RouteLeg]
    public var distanceM: Double
    public var timeS: Double
    public var maneuvers: [Maneuver]
}

struct MinHeap {
    var keys: [Double] = []
    var vals: [Int] = []

    var isEmpty: Bool { return keys.isEmpty }

    mutating func push(_ k: Double, _ v: Int) {
        keys.append(k)
        vals.append(v)
        var i = keys.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if keys[p] <= keys[i] { break }
            keys.swapAt(p, i)
            vals.swapAt(p, i)
            i = p
        }
    }

    mutating func pop() -> (Double, Int)? {
        if keys.isEmpty { return nil }
        let topK = keys[0]
        let topV = vals[0]
        let lastK = keys.removeLast()
        let lastV = vals.removeLast()
        if !keys.isEmpty {
            keys[0] = lastK
            vals[0] = lastV
            var i = 0
            let n = keys.count
            while true {
                let l = 2 * i + 1
                let r = l + 1
                var m = i
                if l < n && keys[l] < keys[m] { m = l }
                if r < n && keys[r] < keys[m] { m = r }
                if m == i { break }
                keys.swapAt(m, i)
                vals.swapAt(m, i)
                i = m
            }
        }
        return (topK, topV)
    }
}

struct LegSpec {
    var segment: Int
    var reversed: Bool
    var from: Double
    var to: Double
}

public final class Router {
    public let graph: GraphData
    private let marker: VisitMarker
    private let lock = NSLock()
    /// Самая быстрая возможная скорость, м/с (для A*).
    private let maxSpeed = 36.0

    public init(graph: GraphData) {
        self.graph = graph
        self.marker = VisitMarker(count: graph.segCount)
    }

    // MARK: привязка к дороге

    /// Находит ближайшую дорогу. `heading` (градусы) помогает выбрать дорогу, по которой едем.
    public func snap(_ c: Coord, maxDistance: Double = 250, heading: Double? = nil,
                     routableOnly: Bool = true) -> SnapResult? {
        lock.lock()
        defer { lock.unlock() }
        var radius = 120.0
        var best: SnapResult? = nil
        var bestScore = Double.infinity
        while true {
            let dLat = radius / Geo.metersPerDegree
            let dLon = radius / (Geo.metersPerDegree * cos(c.lat * Double.pi / 180))
            graph.forEachSegment(level: 2, minLat: c.lat - dLat, minLon: c.lon - dLon,
                                 maxLat: c.lat + dLat, maxLon: c.lon + dLon, marker: marker) { s in
                let seg = graph.segment(s)
                if routableOnly && !seg.isRoutable { return }
                let pts = graph.geometry(of: seg)
                var cum: [Double] = [0]
                var total = 0.0
                for i in 1..<pts.count {
                    total += Geo.distance(pts[i - 1], pts[i])
                    cum.append(total)
                }
                var segBest = Double.infinity
                var segDist = 0.0
                var segAlong = 0.0
                var segPoint = pts[0]
                for i in 0..<(pts.count - 1) {
                    let pr = Geo.project(c, pts[i], pts[i + 1])
                    var score = pr.dist
                    if let h = heading {
                        let pb = Geo.bearing(from: pts[i], to: pts[i + 1])
                        let fwd = abs(Geo.angleDiff(h, pb))
                        let bwd = abs(Geo.angleDiff(h, pb + 180))
                        var diff = min(fwd, bwd)
                        if !seg.canReverse { diff = fwd }
                        if !seg.canForward { diff = bwd }
                        score += diff / 90.0 * 25.0
                    }
                    if score < segBest {
                        segBest = score
                        segDist = pr.dist
                        segAlong = cum[i] + pr.t * (cum[i + 1] - cum[i])
                        segPoint = pr.point
                    }
                }
                if segBest < bestScore {
                    bestScore = segBest
                    let scale = (total > 0 && seg.lengthM > 0) ? Double(seg.lengthM) / total : 1.0
                    best = SnapResult(segment: s, along: segAlong * scale, point: segPoint,
                                      distance: segDist, segLength: Double(seg.lengthM))
                }
            }
            if best != nil && bestScore <= radius { break }
            if radius >= maxDistance { break }
            radius = min(radius * 2.5, maxDistance)
        }
        if let b = best, b.distance <= maxDistance { return b }
        return nil
    }

    // MARK: маршрут

    public func route(from: Coord, to: Coord, startHeading: Double? = nil) -> Route? {
        guard let a = snap(from, heading: startHeading), let b = snap(to) else { return nil }
        return route(from: a, to: b)
    }

    public func route(from a: SnapResult, to b: SnapResult) -> Route? {
        let segA = graph.segment(a.segment)
        let segB = graph.segment(b.segment)
        let LA = max(Double(segA.lengthM), 0.001)
        let LB = max(Double(segB.lengthM), 0.001)

        var bestCost = Double.infinity
        var bestLegs: [LegSpec] = []

        // Обе точки на одном сегменте
        if a.segment == b.segment {
            if segA.canForward && b.along >= a.along - 0.01 {
                let cost = Double(segA.timeS) * (b.along - a.along) / LA
                if cost < bestCost {
                    bestCost = cost
                    bestLegs = [LegSpec(segment: a.segment, reversed: false, from: a.along, to: b.along)]
                }
            }
            if segA.canReverse && b.along <= a.along + 0.01 {
                let cost = Double(segA.timeS) * (a.along - b.along) / LA
                if cost < bestCost {
                    bestCost = cost
                    bestLegs = [LegSpec(segment: a.segment, reversed: true, from: a.along, to: b.along)]
                }
            }
        }

        // Начальные узлы
        var seeds: [Int: (cost: Double, leg: LegSpec)] = [:]
        if segA.canForward {
            let cost = Double(segA.timeS) * (LA - a.along) / LA
            let leg = LegSpec(segment: a.segment, reversed: false, from: a.along, to: LA)
            if let old = seeds[segA.v], old.cost <= cost {} else { seeds[segA.v] = (cost, leg) }
        }
        if segA.canReverse {
            let cost = Double(segA.timeS) * a.along / LA
            let leg = LegSpec(segment: a.segment, reversed: true, from: a.along, to: 0)
            if let old = seeds[segA.u], old.cost <= cost {} else { seeds[segA.u] = (cost, leg) }
        }
        // Конечные узлы
        var goals: [Int: (extra: Double, leg: LegSpec)] = [:]
        if segB.canForward {
            let extra = Double(segB.timeS) * b.along / LB
            let leg = LegSpec(segment: b.segment, reversed: false, from: 0, to: b.along)
            if let old = goals[segB.u], old.extra <= extra {} else { goals[segB.u] = (extra, leg) }
        }
        if segB.canReverse {
            let extra = Double(segB.timeS) * (LB - b.along) / LB
            let leg = LegSpec(segment: b.segment, reversed: true, from: LB, to: b.along)
            if let old = goals[segB.v], old.extra <= extra {} else { goals[segB.v] = (extra, leg) }
        }

        if !seeds.isEmpty && !goals.isEmpty {
            let N = graph.nodeCount
            var g = [Double](repeating: Double.infinity, count: N)
            var prevArc = [UInt32](repeating: 0xFFFF_FFFF, count: N)
            var closed = [Bool](repeating: false, count: N)
            var heap = MinHeap()
            let dest = b.point
            let hFactor = 1.0 / maxSpeed
            for (node, s) in seeds {
                if s.cost < g[node] {
                    g[node] = s.cost
                    heap.push(s.cost + Geo.distance(graph.node(node), dest) * hFactor, node)
                }
            }
            var bestGoalTotal = Double.infinity
            var bestGoalNode = -1
            while let (key, n) = heap.pop() {
                if key >= bestGoalTotal || key >= bestCost { break }
                if closed[n] { continue }
                closed[n] = true
                if let goal = goals[n] {
                    let total = g[n] + goal.extra
                    if total < bestGoalTotal {
                        bestGoalTotal = total
                        bestGoalNode = n
                    }
                }
                let a0 = graph.arcStart(n)
                let a1 = graph.arcStart(n + 1)
                if a0 < a1 {
                    for k in a0..<a1 {
                        let code = graph.arc(k)
                        let s = Int(code & 0x7FFF_FFFF)
                        let rev = (code >> 31) == 1
                        let seg = graph.segment(s)
                        let to = rev ? seg.u : seg.v
                        if closed[to] { continue }
                        let ng = g[n] + Double(seg.timeS)
                        if ng < g[to] {
                            g[to] = ng
                            prevArc[to] = code
                            heap.push(ng + Geo.distance(graph.node(to), dest) * hFactor, to)
                        }
                    }
                }
            }
            if bestGoalNode >= 0 && bestGoalTotal < bestCost {
                var mids: [LegSpec] = []
                var cur = bestGoalNode
                while prevArc[cur] != 0xFFFF_FFFF {
                    let code = prevArc[cur]
                    let s = Int(code & 0x7FFF_FFFF)
                    let rev = (code >> 31) == 1
                    let seg = graph.segment(s)
                    let L = Double(seg.lengthM)
                    mids.append(LegSpec(segment: s, reversed: rev, from: rev ? L : 0, to: rev ? 0 : L))
                    cur = rev ? seg.v : seg.u
                }
                mids.reverse()
                var legs: [LegSpec] = []
                if let seed = seeds[cur] { legs.append(seed.leg) }
                legs.append(contentsOf: mids)
                if let goal = goals[bestGoalNode] { legs.append(goal.leg) }
                bestLegs = legs
                bestCost = bestGoalTotal
            }
        }
        if bestLegs.isEmpty { return nil }
        return buildRoute(bestLegs)
    }

    // MARK: сборка маршрута

    func buildRoute(_ specs: [LegSpec]) -> Route? {
        var coords: [Coord] = []
        var legs: [RouteLeg] = []
        var totalLen = 0.0
        var totalTime = 0.0
        for spec in specs {
            // участки нулевой длины (старт или финиш ровно на перекрёстке) не нужны
            if abs(spec.to - spec.from) < 0.05 && specs.count > 1 { continue }
            let seg = graph.segment(spec.segment)
            let prof = graph.profile(spec.segment)
            let pts = prof.cut(from: spec.from, to: spec.to)
            let len = abs(spec.to - spec.from)
            let time = prof.length > 0 ? Double(seg.timeS) * len / prof.length : 0
            let first = coords.count
            for (i, p) in pts.enumerated() {
                if i == 0, let last = coords.last, Geo.distance(last, p) < 0.5 { continue }
                coords.append(p)
            }
            if coords.isEmpty { continue }
            var lastIdx = coords.count - 1
            if lastIdx < first { lastIdx = first }
            let L = Double(seg.lengthM)
            let atEnd = spec.reversed ? (spec.to <= 0.01) : (spec.to >= L - 0.01)
            let endNode = atEnd ? (spec.reversed ? seg.u : seg.v) : -1
            legs.append(RouteLeg(segment: spec.segment, reversed: spec.reversed,
                                 fromAlong: spec.from, toAlong: spec.to, lengthM: len, timeS: time,
                                 name: graph.name(seg.nameId), cls: Int(seg.cls),
                                 isRoundabout: seg.isRoundabout,
                                 firstCoord: max(first - (first > 0 && legs.count > 0 ? 1 : 0), 0),
                                 lastCoord: lastIdx, endNode: endNode))
            totalLen += len
            totalTime += time
        }
        if coords.count < 2 || legs.isEmpty { return nil }
        // убираем ноги нулевой длины, если есть другие
        var route = Route(coords: coords, legs: legs, distanceM: totalLen, timeS: totalTime, maneuvers: [])
        route.maneuvers = Guidance.maneuvers(route: route, graph: graph)
        return route
    }
}
