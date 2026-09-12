import AppKit
import MicaraCore

// MARK: - Réglages

/// Tout ce qui est persistant, avec sa clé. Le code d'espace et le jeton sont
/// dans `Account`, pas ici.
enum Settings {
    private static let store = UserDefaults.standard

    /// Méthode de mixage choisie dans le menu, changeable en réunion.
    static var mixMode: MixMode {
        get { MixMode(rawValue: store.string(forKey: "mixMode") ?? "") ?? .dominance }
        set { store.set(newValue.rawValue, forKey: "mixMode") }
    }

    /// Chemin du checkout git d'où `build.sh --install` a été lancé. C'est là
    /// que « Mettre à jour » relance `git pull && ./build.sh --install`.
    static var sourcePath: String? {
        get { store.string(forKey: "sourcePath") }
        set { store.set(newValue, forKey: "sourcePath") }
    }

    /// Réunions démarrées, pour le menu.
    static var meetingsStarted: Int {
        get { store.integer(forKey: "meetingsStarted") }
        set { store.set(newValue, forKey: "meetingsStarted") }
    }
}

// MARK: - Journal

/// `~/Library/Logs/micara.log`, en ajout, plafonné : l'app tourne des mois.
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
