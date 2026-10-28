import Foundation
import CryptoKit
import NavCore

struct MapPlace {
    let name: String
    let lat: Double
    let lon: Double
    let sub: Int
}

/// Загруженная карта: дороги, области, поиск и маршрутизатор.
final class MapEngine {
    let graph: GraphData
    let areas: AreaData
    let search: SearchIndex
    let router: Router
    let places: [MapPlace]
    let visit: VisitMarker
    let areaVisit: VisitMarker
    private var nameCache: [UInt32: String] = [:]

    init(dir: URL) throws {
        graph = try GraphData(path: dir.appendingPathComponent("graph.bin").path)
        areas = try AreaData(path: dir.appendingPathComponent("areas.bin").path)
        search = try SearchIndex(path: dir.appendingPathComponent("search.bin").path)
        router = Router(graph: graph)
        visit = VisitMarker(count: graph.segCount)
        areaVisit = VisitMarker(count: areas.featCount)
        search.prepare()
        // населённые пункты для подписей на карте
        let all = search.places(minLat: -90, minLon: -180, maxLat: 90, maxLon: 180, maxSub: 4, limit: 100_000)
        places = all.map { MapPlace(name: $0.name, lat: $0.coord.lat, lon: $0.coord.lon, sub: $0.sub) }
    }

    /// Название улицы по номеру (с запоминанием). Только из главного потока.
    func streetName(_ id: UInt32) -> String? {
        if id == 0xFFFF_FFFF { return nil }
        if let n = nameCache[id] { return n }
        guard let n = graph.name(id) else { return nil }
        if nameCache.count > 4000 { nameCache.removeAll(keepingCapacity: true) }
        nameCache[id] = n
        return n
    }
}

enum MapStatus {
    case missing
    case checking
    case downloading(progress: Double, text: String)
    case verifying
    case loading
    case installed(sizeText: String)
    case failed(String)
}

struct MapManifestFile: Decodable {
    let name: String
    let size: Int64
    let sha256: String
}

struct MapManifest: Decodable {
    let version: Int
    let built: String
    let files: [MapManifestFile]
}

/// Скачивает карту с GitHub, проверяет и загружает.
final class MapStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var status: MapStatus = .missing
    @Published var engine: MapEngine?

    static let baseURL = URL(string: "https://github.com/svenki45/kyiv-nav/releases/download/map-v1/")!

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg, delegate: self, delegateQueue: OperationQueue.main)
    }()

    private var manifest: MapManifest?
    private var fileIndex = 0
    private var doneBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var currentTask: URLSessionDownloadTask?
    private var cancelled = false

    private var rootDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KyivNav", isDirectory: true)
    }
    var mapDir: URL { return rootDir.appendingPathComponent("map", isDirectory: true) }
    private var newDir: URL { return rootDir.appendingPathComponent("map_new", isDirectory: true) }

    override init() {
        super.init()
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        var u = rootDir
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
        loadIfInstalled()
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        return ["graph.bin", "areas.bin", "search.bin"].allSatisfy {
            fm.fileExists(atPath: mapDir.appendingPathComponent($0).path)
        }
    }

    // MARK: загрузка в память

    func loadIfInstalled() {
        if !isInstalled {
            status = .missing
            return
        }
        status = .loading
        let dir = mapDir
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let e = try MapEngine(dir: dir)
                DispatchQueue.main.async {
                    self?.engine = e
                    self?.status = .installed(sizeText: self?.installedSizeText() ?? "")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.engine = nil
                    self?.status = .failed("Файли карти пошкоджені. Видаліть і завантажте знову.")
                }
            }
        }
    }

    private func installedSizeText() -> String {
        var total: Int64 = 0
        for n in ["graph.bin", "areas.bin", "search.bin"] {
            let p = mapDir.appendingPathComponent(n).path
            if let a = try? FileManager.default.attributesOfItem(atPath: p), let s = a[.size] as? NSNumber {
                total += s.int64Value
            }
        }
        return MapStore.mb(total)
    }

    static func mb(_ bytes: Int64) -> String {
        return String(format: "%.0f МБ", Double(bytes) / 1_000_000)
    }

    // MARK: скачивание

    func download() {
        cancelled = false
        status = .checking
        let url = MapStore.baseURL.appendingPathComponent("manifest.json")
        let task = session.dataTask(with: url) { [weak self] data, resp, err in
            guard let self = self else { return }
            if let err = err {
                self.fail("Немає зв'язку з сервером: \(err.localizedDescription)")
                return
            }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, let data = data else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                self.fail("Сервер відповів \(code). Якщо 404 — репозиторій на GitHub має бути відкритим (Public).")
                return
            }
            guard let m = try? JSONDecoder().decode(MapManifest.self, from: data), !m.files.isEmpty else {
                self.fail("Не вдалося прочитати список файлів карти.")
                return
            }
            self.manifest = m
            self.startFiles()
        }
        task.resume()
    }

    private func startFiles() {
        guard let m = manifest else { return }
        try? FileManager.default.removeItem(at: newDir)
        do {
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        } catch {
            fail("Не вдалося створити папку для карти.")
            return
        }
        fileIndex = 0
        doneBytes = 0
        totalBytes = m.files.reduce(0) { $0 + $1.size }
        status = .downloading(progress: 0, text: "0 з \(MapStore.mb(totalBytes))")
        startCurrentFile()
    }

    private func startCurrentFile() {
        guard let m = manifest, fileIndex < m.files.count else { return }
        let f = m.files[fileIndex]
        let task = session.downloadTask(with: MapStore.baseURL.appendingPathComponent(f.name))
        currentTask = task
        task.resume()
    }

    func cancel() {
        cancelled = true
        currentTask?.cancel()
        currentTask = nil
        try? FileManager.default.removeItem(at: newDir)
        loadIfInstalledOrMissing()
    }

    private func loadIfInstalledOrMissing() {
        if engine != nil, isInstalled {
            status = .installed(sizeText: installedSizeText())
        } else {
            status = isInstalled ? .loading : .missing
            if isInstalled { loadIfInstalled() }
        }
    }

    func delete() {
        engine = nil
        try? FileManager.default.removeItem(at: mapDir)
        status = .missing
    }

    private func fail(_ text: String) {
        DispatchQueue.main.async {
            try? FileManager.default.removeItem(at: self.newDir)
            self.status = .failed(text)
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let done = doneBytes + totalBytesWritten
        let p = totalBytes > 0 ? min(Double(done) / Double(totalBytes), 1) : 0
        status = .downloading(progress: p, text: "\(MapStore.mb(done)) з \(MapStore.mb(totalBytes))")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let m = manifest, fileIndex < m.files.count else { return }
        let f = m.files[fileIndex]
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            fail("Файл \(f.name): сервер відповів \(http.statusCode).")
            return
        }
        let dest = newDir.appendingPathComponent(f.name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            fail("Не вдалося зберегти файл \(f.name).")
            return
        }
        // проверка размера
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? -1
        if size != f.size {
            fail("Файл \(f.name) завантажився не повністю. Спробуйте ще раз.")
            return
        }
        doneBytes += f.size
        fileIndex += 1
        if fileIndex < m.files.count {
            startCurrentFile()
        } else {
            finishInstall()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        if cancelled { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        fail("Завантаження перервано: \(error.localizedDescription)")
    }

    // MARK: проверка и установка

    private func finishInstall() {
        guard let m = manifest else { return }
        status = .verifying
        let dir = newDir
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for f in m.files {
                let p = dir.appendingPathComponent(f.name)
                if MapStore.sha256(of: p) != f.sha256 {
                    self?.fail("Контрольна сума файлу \(f.name) не збіглася. Спробуйте ще раз.")
                    return
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let fm = FileManager.default
                self.engine = nil
                try? fm.removeItem(at: self.mapDir)
                do {
                    try fm.moveItem(at: self.newDir, to: self.mapDir)
                } catch {
                    self.status = .failed("Не вдалося встановити карту.")
                    return
                }
                self.loadIfInstalled()
            }
        }
    }

    static func sha256(of url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = h.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
