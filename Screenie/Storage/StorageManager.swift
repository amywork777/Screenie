import Foundation

struct StorageManager {
    private let cacheDir: URL
    private let archiveDir: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("Screenie", isDirectory: true)

        let home = FileManager.default.homeDirectoryForCurrentUser
        archiveDir = home
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent("Screenie", isDirectory: true)

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
    }

    func newSessionDir() -> URL {
        let name = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = cacheDir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func archivePath() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let name = "screenie-\(formatter.string(from: Date())).mp4"
        return archiveDir.appendingPathComponent(name)
    }

    func cleanupSession(dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    func recentArchives(limit: Int = 5) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: archiveDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "mp4" }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return aDate > bDate
            }
            .prefix(limit)
            .map { $0 }
    }
}
