import AppKit

// MARK: - Mises à jour

/// Même modèle qu'Eyesaver : une requête anonyme par jour vers la dernière
/// release GitHub, comparaison de versions. Différence : « Mettre à jour »
/// fait le travail lui-même (`git pull && ./build.sh --install` dans le
/// checkout d'origine) au lieu d'ouvrir la page de release. Le script tue
/// l'app en cours et relance la nouvelle : rien à faire ensuite.
enum Updater {
    static let repository = "GNRNicolas/micara-mac"
    static let homepage = URL(string: "https://github.com/GNRNicolas/micara-mac")!
    private static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private static var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `manual` : déclenché depuis le menu, rapporte aussi « à jour » et
    /// ignore la limite d'une fois par jour.
    static func check(manual: Bool) {
        if !manual, let last = lastCheck, Date().timeIntervalSince(last) < checkInterval { return }
        lastCheck = Date()

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                AppLog.write("vérification de mise à jour : \(error.localizedDescription)")
                if manual { DispatchQueue.main.async { report(failure: error.localizedDescription) } }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else {
                AppLog.write("vérification de mise à jour : réponse illisible")
                if manual { DispatchQueue.main.async { report(failure: "Réponse de GitHub illisible.") } }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            AppLog.write("mise à jour : locale \(currentVersion), dernière \(latest)")
            DispatchQueue.main.async {
                if isNewer(latest, than: currentVersion) { offer(version: latest) }
                else if manual { report(upToDate: currentVersion) }
            }
        }.resume()
    }

    /// Comparaison composant par composant : 1.10 bat 1.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func offer(version: String) {
        let alert = NSAlert()
        alert.messageText = "Micara \(version) est disponible"
        alert.informativeText = "Vous utilisez la version \(currentVersion). La mise à jour se compile depuis les sources et relance l'app : une minute environ."
        alert.addButton(withTitle: "Mettre à jour")
        alert.addButton(withTitle: "Plus tard")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { install() }
    }

    /// Lance `git pull && ./build.sh --install` dans le checkout d'origine.
    /// `build.sh --install` tue l'app en cours et relance la nouvelle, donc ce
    /// process disparaît en route : le résultat est dans le journal.
    /// Sans checkout connu (app copiée à la main), on ouvre la page de release.
    static func install() {
        guard let source = Settings.sourcePath,
              FileManager.default.fileExists(atPath: source + "/build.sh") else {
            AppLog.write("mise à jour : checkout introuvable, ouverture de la page de release")
            NSWorkspace.shared.open(homepage.appendingPathComponent("releases/latest"))
            return
        }
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/micara-update.log").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Le script tourne détaché de l'app (nohup + &) : quand build.sh tue
        // l'app, le shell continue jusqu'au relancement.
        process.arguments = ["-c", "cd \"\(source)\" && nohup bash -c 'git pull --ff-only && ./build.sh --install' > \"\(log)\" 2>&1 &"]
        do {
            try process.run()
            AppLog.write("mise à jour lancée depuis \(source), journal \(log)")
        } catch {
            report(failure: "Impossible de lancer la mise à jour : \(error.localizedDescription)")
        }
    }

    private static func report(upToDate version: String) {
        let alert = NSAlert()
        alert.messageText = "Micara est à jour"
        alert.informativeText = "Vous utilisez la version \(version)."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func report(failure: String) {
        let alert = NSAlert()
        alert.messageText = "Vérification impossible"
        alert.informativeText = failure
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
