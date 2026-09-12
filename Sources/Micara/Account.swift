import Foundation

// MARK: - Device account

/// Micara has no login: on first launch the app asks the server for an
/// anonymous space (`POST /api/device/register`) and gets back a permanent
/// code (the one in the QR) and an api token. The code is no secret on the Mac
/// side (it is shown as a QR to every participant): UserDefaults. The token
/// opens the bridge WebSocket and lasts for the life of the account: a file
/// readable by its owner only (0600), see `TokenFile` for why not the keychain.
enum Account {
    static var serverURL: URL {
        // Overridable to test against a local server:
        //   defaults write com.getmicara.mac serverURL http://localhost:3000
        if let raw = UserDefaults.standard.string(forKey: "serverURL"), let url = URL(string: raw) { return url }
        return URL(string: "https://app.getmicara.com")!
    }

    static var code: String? {
        get { UserDefaults.standard.string(forKey: "spaceCode") }
        set { UserDefaults.standard.set(newValue, forKey: "spaceCode") }
    }

    static var token: String? {
        get { TokenFile.read() }
        set { if let newValue { TokenFile.write(newValue) } else { TokenFile.delete() } }
    }

    static var isRegistered: Bool { code != nil && token != nil }

    /// The URL phones scan.
    static var joinURL: URL? {
        guard let code else { return nil }
        return serverURL.appendingPathComponent("r").appendingPathComponent(code)
    }

    struct Registration: Decodable { let token: String; let code: String }

    enum AccountError: LocalizedError {
        case http(Int, String?)
        case unreadable
        var errorDescription: String? {
            switch self {
            case .http(let status, let message): return message ?? "the server answered \(status)"
            case .unreadable: return "unreadable server response"
            }
        }
    }

    /// Idempotent: does nothing if the device is already registered. The name
    /// sent is only a log label on the server side.
    static func ensureRegistered(completion: @escaping (Result<Void, Error>) -> Void) {
        if isRegistered { completion(.success(())); return }
        var request = URLRequest(url: serverURL.appendingPathComponent("api/device/register"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": Host.current().localizedName ?? "Mac"])
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Void, Error>
            defer { DispatchQueue.main.async { completion(result) } }
            if let error { result = .failure(error); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else { result = .failure(AccountError.unreadable); return }
            guard status == 201 else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                result = .failure(AccountError.http(status, message))
                return
            }
            guard let reg = try? JSONDecoder().decode(Registration.self, from: data) else {
                result = .failure(AccountError.unreadable)
                return
            }
            // Token first: if writing it fails, the app stays "not registered"
            // and will try again, rather than ending up with a code and no
            // token.
            TokenFile.write(reg.token)
            code = reg.code
            AppLog.write("device registered, space \(reg.code)")
            result = .success(())
        }.resume()
    }

    /// Presence: the server considers the bridge asleep after 90 s without a
    /// heartbeat. Sent every 30 s during a meeting, like the old bridge.
    static func heartbeat(state: String) {
        guard let token else { return }
        var request = URLRequest(url: serverURL.appendingPathComponent("api/bridge/heartbeat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["version": Updater.currentVersion, "state": state])
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error { AppLog.write("heartbeat: \(error.localizedDescription)") }
            else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                AppLog.write("heartbeat: HTTP \(status)")
            }
        }.resume()
    }
}

// MARK: - Token

/// The token lives in a file readable by its owner alone (mode 0600), not in
/// the keychain. The keychain would be safer on paper, but it identifies an
/// app by its code signature, and the ad-hoc signature changes on EVERY build:
/// after each install or update, macOS put up "Micara wants to use your
/// confidential information…" and asked for the login password. A frightening
/// prompt, on every update, to protect a token that only opens a space whose
/// code is shown as a QR to every participant anyway. The file is protected by
/// the macOS account and FileVault; that is the level of the rest of
/// `~/Library`.
enum TokenFile {
    private static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Micara", isDirectory: true)
    private static let url = directory.appendingPathComponent("token")

    static func read() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func write(_ value: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(value.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            AppLog.write("token: cannot write: \(error.localizedDescription)")
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
