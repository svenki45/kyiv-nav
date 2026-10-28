import Foundation

public enum PlaceKind: Int {
    case street = 0
    case place = 1
    case poi = 2
}

public struct SearchResult {
    public var name: String
    public var detail: String
    public var coord: Coord
    public var kind: PlaceKind
    public var sub: Int
}

/// Поиск улиц, населённых пунктов и мест (файл search.bin).
public final class SearchIndex {
    let f: MappedFile
    public let count: Int
    let stringCount: Int
    let oEntries: Int, oStrOff: Int, oBlob: Int
    private var lower: [String] = []

    public init(path: String) throws {
        f = try MappedFile(path: path)
        if !f.hasMagic("KSRC") || f.u32(4) != 1 { throw NavError.badFile(path) }
        count = Int(f.u32(8))
        stringCount = Int(f.u32(12))
        oEntries = Int(f.u32(16))
        oStrOff = Int(f.u32(20))
        oBlob = Int(f.u32(24))
    }

    /// Готовит строки для быстрого поиска. Вызывать один раз в фоне.
    public func prepare() {
        if !lower.isEmpty { return }
        var arr: [String] = []
        arr.reserveCapacity(stringCount)
        for i in 0..<stringCount { arr.append(string(i).lowercased()) }
        lower = arr
    }

    public func string(_ i: Int) -> String {
        let a = Int(f.u32(oStrOff + 4 * i))
        let b = Int(f.u32(oStrOff + 4 * i + 4))
        return f.string(oBlob + a, b - a)
    }

    struct Entry {
        var kind: Int
        var sub: Int
        var lat: Double
        var lon: Double
        var nameIdx: Int
        var extraIdx: Int
    }

    func entry(_ i: Int) -> Entry {
        let o = oEntries + 20 * i
        let extra = f.u32(o + 16)
        return Entry(kind: Int(f.u8(o)), sub: Int(f.u8(o + 1)),
                     lat: Double(f.i32(o + 4)) / 1e7, lon: Double(f.i32(o + 8)) / 1e7,
                     nameIdx: Int(f.u32(o + 12)), extraIdx: extra == 0xFFFF_FFFF ? -1 : Int(extra))
    }

    /// Для подписей на карте: города, сёла и т.п. внутри прямоугольника.
    public func places(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
                       maxSub: Int, limit: Int) -> [SearchResult] {
        var out: [SearchResult] = []
        for i in 0..<count {
            let o = oEntries + 20 * i
            if f.u8(o) != 1 { continue }
            let sub = Int(f.u8(o + 1))
            if sub > maxSub { continue }
            let lat = Double(f.i32(o + 4)) / 1e7
            let lon = Double(f.i32(o + 8)) / 1e7
            if lat < minLat || lat > maxLat || lon < minLon || lon > maxLon { continue }
            out.append(SearchResult(name: string(Int(f.u32(o + 12))), detail: "",
                                    coord: Coord(lat: lat, lon: lon), kind: .place, sub: sub))
            if out.count >= limit { break }
        }
        return out
    }

    public func search(_ query: String, near: Coord?, limit: Int = 30) -> [SearchResult] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.count < 2 || lower.isEmpty { return [] }
        let tokens = q.split(separator: " ").map { String($0) }
        var scored: [(Double, Int)] = []
        for i in 0..<count {
            let o = oEntries + 20 * i
            let nameIdx = Int(f.u32(o + 12))
            let s = lower[nameIdx]
            var ok = true
            for t in tokens where !s.contains(t) { ok = false; break }
            if !ok { continue }
            var score = 0.0
            if s.hasPrefix(tokens[0]) { score += 40 } else if s.contains(" " + tokens[0]) { score += 20 }
            score -= Double(s.count) * 0.3
            let kind = Int(f.u8(o))
            let sub = Int(f.u8(o + 1))
            if kind == 1 { score += sub == 0 ? 30 : (sub == 1 ? 18 : 8) }
            if let n = near {
                let lat = Double(f.i32(o + 4)) / 1e7
                let lon = Double(f.i32(o + 8)) / 1e7
                let d = Geo.distance(n, Coord(lat: lat, lon: lon)) / 1000
                score -= min(d, 400) * 0.25
            }
            scored.append((score, i))
        }
        scored.sort { $0.0 > $1.0 }
        var out: [SearchResult] = []
        for (_, i) in scored.prefix(limit) {
            let e = entry(i)
            var detail = ""
            if e.kind == 0 {
                detail = e.extraIdx >= 0 ? string(e.extraIdx) : "вулиця"
            } else if e.kind == 1 {
                detail = ["місто", "містечко", "село", "район", "хутір"][min(e.sub, 4)]
            } else {
                detail = ["місце", "їжа", "магазин", "АЗС", "медицина", "готель, туризм", "банк", "місце"][min(e.sub, 7)]
            }
            out.append(SearchResult(name: string(e.nameIdx), detail: detail,
                                    coord: Coord(lat: e.lat, lon: e.lon),
                                    kind: PlaceKind(rawValue: e.kind) ?? .poi, sub: e.sub))
        }
        return out
    }
}
