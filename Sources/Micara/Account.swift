import Foundation

// MARK: - Compte appareil

/// Micara n'a plus de login : à la première ouverture, l'app demande au
/// serveur un espace anonyme (`POST /api/device/register`) et reçoit un code
/// permanent (celui du QR) et un jeton api. Le code n'est pas un secret côté
/// Mac (il est affiché en QR à tous les participants) : UserDefaults. Le jeton
/// ouvre le WebSocket bridge et vaut pour la vie du compte : fichier réservé à
/// l'utilisateur (0600), voir `TokenFile` pour le choix contre le trousseau.
enum Account {
    static var serverURL: URL {
        // Surchargeable pour tester contre un serveur local :
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

    /// URL que les téléphones scannent.
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
            case .http(let status, let message): return message ?? "le serveur a répondu \(status)"
            case .unreadable: return "réponse du serveur illisible"
            }
        }
    }

    /// Idempotent : ne fait rien si l'appareil est déjà enregistré. Le nom
    /// envoyé n'est qu'un libellé de journal côté serveur.
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
            // Le jeton d'abord : si son écriture échoue, l'app reste
            // « non enregistrée » et réessaiera, plutôt que d'avoir un code
            // sans jeton.
            TokenFile.write(reg.token)
            code = reg.code
            AppLog.write("appareil enregistré, espace \(reg.code)")
            result = .success(())
        }.resume()
    }

    /// Présence : le serveur considère le bridge endormi sans heartbeat depuis
    /// 90 s. Envoyé toutes les 30 s pendant une réunion, comme l'ancien bridge.
    static func heartbeat(state: String) {
        guard let token else { return }
        var request = URLRequest(url: serverURL.appendingPathComponent("api/bridge/heartbeat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["version": Updater.currentVersion, "state": state])
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error { AppLog.write("heartbeat : \(error.localizedDescription)") }
            else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                AppLog.write("heartbeat : HTTP \(status)")
            }
        }.resume()
    }
}

// MARK: - Jeton

/// Le jeton vit dans un fichier lisible par l'utilisateur seul (mode 0600),
/// pas dans le trousseau. Le trousseau serait plus sûr sur le papier, mais il
/// identifie l'app par sa signature de code, et la signature ad hoc change à
/// CHAQUE build : après chaque installation ou mise à jour, macOS affichait
/// « Micara veut utiliser vos informations confidentielles… » avec demande du
/// mot de passe de session. Un message qui fait peur, à chaque mise à jour,
/// pour protéger un jeton qui ne donne accès qu'à un espace dont le code est
/// de toute façon affiché en QR à tous les participants. Le fichier est
/// protégé par le compte macOS et FileVault ; c'est le niveau du reste de
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
            AppLog.write("jeton : écriture impossible : \(error.localizedDescription)")
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
