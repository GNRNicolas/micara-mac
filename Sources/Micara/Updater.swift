import AppKit

// MARK: - Updates

/// Same model as Eyesaver: one anonymous request a day to the latest GitHub
/// release, then a version comparison. The difference: **Update** does the work
/// itself (`git pull && ./build.sh --install` in the original checkout) instead
/// of opening the release page. The script kills the running app and starts the
/// new one: nothing left to do afterwards.
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

    /// `manual`: triggered from the menu, so it also reports "up to date" and
    /// ignores the once-a-day limit.
    static func check(manual: Bool) {
        if !manual, let last = lastCheck, Date().timeIntervalSince(last) < checkInterval { return }
        lastCheck = Date()

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                AppLog.write("update check: \(error.localizedDescription)")
                if manual { DispatchQueue.main.async { report(failure: error.localizedDescription) } }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else {
                AppLog.write("update check: unreadable response")
                if manual { DispatchQueue.main.async { report(failure: "GitHub sent an unreadable response.") } }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            AppLog.write("update: local \(currentVersion), latest \(latest)")
            DispatchQueue.main.async {
                if isNewer(latest, than: currentVersion) { offer(version: latest) }
                else if manual { report(upToDate: currentVersion) }
            }
        }.resume()
    }

    /// Component by component, so 1.10 beats 1.9.
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
        alert.messageText = "Micara \(version) is available"
        alert.informativeText = "You are running version \(currentVersion). The update builds from source and restarts the app: about a minute."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { install() }
    }

    /// Runs `git pull && ./build.sh --install` in the original checkout.
    /// `build.sh --install` kills the running app and starts the new one, so
    /// this process disappears along the way: the outcome is in the log.
    /// With no known checkout (app copied by hand), open the release page.
    static func install() {
        guard let source = Settings.sourcePath,
              FileManager.default.fileExists(atPath: source + "/build.sh") else {
            AppLog.write("update: checkout not found, opening the release page")
            NSWorkspace.shared.open(homepage.appendingPathComponent("releases/latest"))
            return
        }
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/micara-update.log").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The script runs detached from the app (nohup + &): when build.sh
        // kills the app, the shell carries on to the relaunch.
        process.arguments = ["-c", "cd \"\(source)\" && nohup bash -c 'git pull --ff-only && ./build.sh --install' > \"\(log)\" 2>&1 &"]
        do {
            try process.run()
            AppLog.write("update started from \(source), log \(log)")
        } catch {
            report(failure: "Could not start the update: \(error.localizedDescription)")
        }
    }

    private static func report(upToDate version: String) {
        let alert = NSAlert()
        alert.messageText = "Micara is up to date"
        alert.informativeText = "You are running version \(version)."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func report(failure: String) {
        let alert = NSAlert()
        alert.messageText = "Could not check for updates"
        alert.informativeText = failure
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
