import AppKit
import MicaraCore

// MARK: - Settings

/// Everything persisted, with the key it is stored under. The space code and
/// the token live in `Account`, not here.
enum Settings {
    private static let store = UserDefaults.standard

    /// Mixing method picked from the menu, changeable mid-meeting.
    static var mixMode: MixMode {
        get { MixMode(rawValue: store.string(forKey: "mixMode") ?? "") ?? .dominance }
        set { store.set(newValue.rawValue, forKey: "mixMode") }
    }

    /// Path of the git checkout `build.sh --install` was run from. That is
    /// where **Update** re-runs `git pull && ./build.sh --install`.
    static var sourcePath: String? {
        get { store.string(forKey: "sourcePath") }
        set { store.set(newValue, forKey: "sourcePath") }
    }

    /// Meetings started, for the menu.
    static var meetingsStarted: Int {
        get { store.integer(forKey: "meetingsStarted") }
        set { store.set(newValue, forKey: "meetingsStarted") }
    }
}

// MARK: - Log

/// `~/Library/Logs/micara.log`, appended, capped: the app runs for months.
enum AppLog {
    private static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/micara.log")
    private static let sizeLimit = 256 * 1024
    private static let lock = NSLock()

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end > sizeLimit { try? handle.truncate(atOffset: 0) }
        try? handle.write(contentsOf: data)
    }
}
