import Foundation
import HeadwayCore

/// Where Headway keeps things. Learned data is numbers about head pose only — never camera images.
enum Storage {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Headway", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let logs: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Logs/Headway", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var storeURL: URL { appSupport.appendingPathComponent("learned.json") }

    private static let writeQueue = DispatchQueue(label: "headway.storage")

    static func loadStore() -> CalibrationStore {
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(CalibrationStore.self, from: data) else { return CalibrationStore() }
        guard store.version >= CalibrationStore.currentVersion else {
            // Measured differently: keep a copy, but start over.
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("v\(store.version)"))
            try? FileManager.default.copyItem(at: storeURL, to: storeURL.appendingPathExtension("v\(store.version)"))
            Log.event("calibration from version \(store.version) uses older eye measurements — recalibration needed")
            return CalibrationStore()
        }
        return store
    }

    static func save(_ store: CalibrationStore) {
        writeQueue.async {
            if let data = try? JSONEncoder().encode(store) { try? data.write(to: storeURL, options: .atomic) }
        }
    }

    static func loadSettings() -> HeadwaySettings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(HeadwaySettings.self, from: data) else { return HeadwaySettings() }
        return s
    }

    static func save(_ settings: HeadwaySettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") }
    }
}

/// A plain-text activity log (what Headway did and why) — for debugging, never face data.
/// With `defaults write com.irakli.headway debugReadings -bool YES`, readings are also written
/// to readings.jsonl a few times a second.
enum Log {
    private static let queue = DispatchQueue(label: "headway.log")
    private static let url = Storage.logs.appendingPathComponent("headway.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func event(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { append(line, to: url, rotateAt: 2_000_000) }
    }

    static var debugReadings: Bool { UserDefaults.standard.bool(forKey: "debugReadings") }

    static func reading(_ json: String) {
        let line = json + "\n"
        queue.async { append(line, to: Storage.logs.appendingPathComponent("readings.jsonl"), rotateAt: 20_000_000) }
    }

    private static func append(_ line: String, to url: URL, rotateAt limit: Int) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit {
            let old = url.deletingPathExtension().appendingPathExtension("old.\(url.pathExtension)")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    }
}
