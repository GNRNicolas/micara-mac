import AppKit
import ServiceManagement
import MicaraCore

// Micara pour Mac — l'ordinateur et les téléphones de la salle fusionnent leur
// audio dans un seul micro « Micara » que Teams/Zoom voient comme un micro
// ordinaire. Forme empruntée à Eyesaver : menu bar, pas de Dock, une barre
// non-activante en bas de l'écran, un liseré autour de chaque écran.
//
// Cycle : `idle` ⇄ `meeting`. Tout passe par `startMeeting()` et `endMeeting()`.

final class AppDelegate: NSObject, NSApplicationDelegate, BarDelegate {
    private var statusItem: NSStatusItem!
    private let borders = Borders()
    private lazy var bar = Bar(delegate: self)
    private let inputSwitcher = DefaultInputSwitcher()
    private var audio: AudioEngine?
    private var signal: SignalClient?
    private var heartbeatTimer: Timer?
    private var sharePicker: NSSharingServicePicker?
    private var signalSources: [DispatchSourceSignal] = []

    private enum Phase { case idle, meeting }
    private var phase: Phase = .idle
    private var muted = false

    private let meetingItem = NSMenuItem(title: "Créer une réunion", action: #selector(toggleMeeting), keyEquivalent: "")
    private let muteItem = NSMenuItem(title: "Couper les téléphones", action: #selector(toggleMute), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Ouvrir au démarrage", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
    private let micItem = NSMenuItem(title: "Réinstaller le micro Micara", action: #selector(reinstallMic), keyEquivalent: "")
    private let codeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("--- lancement \(Updater.currentVersion) ---")
        guard !quitIfAlreadyRunning() else { return }
        buildMenu()
        installTestHooks()
        register()

        // Ouvrir au démarrage d'office à la première installation : l'app est
        // conçue pour être oubliée dans la barre de menus. Désactivable au menu.
        if !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            try? SMAppService.mainApp.register()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { Updater.check(manual: false) }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.phase == .meeting else { return }
            self.borders.hide(); self.borders.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitter en réunion ne doit pas laisser Teams sur un micro fantôme.
        if phase == .meeting { endMeeting() }
    }

    /// Deux copies = deux icônes, deux barres, un micro forcé deux fois.
    private func quitIfAlreadyRunning() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { $0 != .current }
        guard let first = others.first else { return false }
        AppLog.write("déjà lancé (pid \(first.processIdentifier)) ; cette copie quitte")
        NSApp.terminate(nil)
        return true
    }

    /// `kill -USR1 <pid>` démarre/termine une réunion : boucle de test sans
    /// passer par le menu.
    private func installTestHooks() {
        Darwin.signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.toggleMeeting() }
        source.resume()
        signalSources.append(source)
    }

    // MARK: Enregistrement

    private func register() {
        Account.ensureRegistered { [weak self] result in
            switch result {
            case .success: self?.refreshMenuState()
            case .failure(let error):
                AppLog.write("enregistrement : \(error.localizedDescription)")
                // Réessai discret : le Mac vient peut-être de se réveiller sans réseau.
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self?.register() }
            }
        }
    }

    // MARK: Barre de menus

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = statusImage()

        let menu = NSMenu()
        menu.autoenablesItems = false
        codeItem.isEnabled = false
        menu.addItem(meetingItem)
        menu.addItem(muteItem)
        menu.addItem(.separator())
        menu.addItem(codeItem)
        menu.addItem(choiceMenu("Mixage", choices: [("Dominance + gate", 0), ("Somme", 1)],
                                selected: Settings.mixMode == .dominance ? 0 : 1, action: #selector(pickMixMode(_:))))
        menu.addItem(loginItem)
        menu.addItem(micItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("Vérifier les mises à jour…", #selector(checkForUpdates)))
        menu.addItem(menuItem("Partager Micara", #selector(shareApp)))
        menu.addItem(menuItem("Star on GitHub", #selector(openRepository)))
        menu.addItem(.separator())
        menu.items.forEach { if $0.action != nil { $0.target = self } }
        menu.addItem(NSMenuItem(title: "Quitter Micara", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
        refreshMenuState()
    }

    /// Le logo Micara (la grille de points du SVG de la marque) dessiné en
    /// image *template* : macOS le teinte lui-même selon la barre de menus
    /// (clair, sombre, fond d'écran vif). Un PNG gris fixe restait gris
    /// partout, illisible sur une barre claire.
    private func statusImage() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            // Coordonnées du logo.svg (viewBox 64), rayon 3.44.
            let dots: [(CGFloat, CGFloat)] = [
                (22.29, 17.60), (41.08, 17.60), (31.69, 26.99), (13.52, 36.38), (13.52, 46.40),
                (13.52, 26.99), (22.29, 26.99), (41.08, 26.99), (50.48, 26.99), (50.48, 36.38),
                (50.48, 46.40), (31.69, 37.01),
            ]
            let scale = rect.width / 64
            let r = 3.44 * scale * 1.15  // un peu plus gras : 18 pt, pas 64
            NSColor.black.setFill()
            for (x, y) in dots {
                NSBezierPath(ovalIn: NSRect(x: x * scale - r, y: y * scale - r, width: 2 * r, height: 2 * r)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    private func choiceMenu(_ title: String, choices: [(String, Int)], selected: Int, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (label, value) in choices {
            let entry = NSMenuItem(title: label, action: action, keyEquivalent: "")
            entry.tag = value
            entry.target = self
            entry.state = value == selected ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    private func refreshMenuState() {
        let inMeeting = phase == .meeting
        meetingItem.title = inMeeting ? "Terminer la réunion" : "Créer une réunion"
        meetingItem.isEnabled = Account.isRegistered || inMeeting
        muteItem.isEnabled = inMeeting
        muteItem.title = muted ? "Réactiver les téléphones" : "Couper les téléphones"
        codeItem.title = Account.code.map { "Code de l'espace : \($0)" } ?? "Enregistrement en cours…"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        micItem.title = MicaraAggregate.blackHoleInstalled ? "Réinstaller le micro Micara" : "Installer le micro Micara…"
    }

    // MARK: Actions du menu

    @objc private func toggleMeeting() {
        switch phase {
        case .idle: startMeeting()
        case .meeting: endMeeting()
        }
    }

    @objc private func toggleMute() {
        muted.toggle()
        audio?.phonesMuted = muted
        bar.setMuted(muted)
        refreshMenuState()
        AppLog.write(muted ? "téléphones coupés" : "téléphones réactivés")
    }

    @objc private func pickMixMode(_ sender: NSMenuItem) {
        Settings.mixMode = sender.tag == 0 ? .dominance : .sum
        sender.menu?.items.forEach { $0.state = ($0 === sender) ? .on : .off }
        audio?.mode = Settings.mixMode
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            AppLog.write("ouvrir au démarrage : \(error.localizedDescription)")
        }
        refreshMenuState()
    }

    /// BlackHole est un driver système : seul son installeur (mot de passe
    /// admin) peut le poser. On ouvre le .pkg embarqué dans Installer.app.
    @objc private func reinstallMic() {
        if MicaraAggregate.blackHoleInstalled {
            do {
                try MicaraAggregate.remove()
                try MicaraAggregate.ensure()
                AppLog.write("agrégat Micara recréé")
            } catch {
                alert("Micro Micara", "Impossible de recréer le micro : \(error)")
            }
            return
        }
        guard let pkg = Bundle.main.url(forResource: "BlackHole16ch-0.7.1", withExtension: "pkg") else {
            alert("Micro Micara", "L'installeur BlackHole manque dans l'app. Relancez ./build.sh --install depuis le Terminal.")
            return
        }
        NSWorkspace.shared.open(pkg)
    }

    @objc private func checkForUpdates() { Updater.check(manual: true) }
    @objc private func openRepository() { NSWorkspace.shared.open(Updater.homepage) }

    @objc private func shareApp() {
        guard let anchor = statusItem.button else { return }
        DispatchQueue.main.async { [self] in
            let picker = NSSharingServicePicker(items: [Updater.homepage])
            sharePicker = picker
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Réunion

    private func startMeeting() {
        guard phase == .idle, let token = Account.token, let joinURL = Account.joinURL else { return }

        // 1. Le micro « Micara » (agrégat autour de BlackHole) existe et devient
        //    le micro par défaut. Sans BlackHole, rien ne peut marcher.
        do {
            try MicaraAggregate.ensure()
            try inputSwitcher.activate()
        } catch AudioDeviceError.blackHoleMissing {
            alert("Micro Micara absent", "BlackHole n'est pas installé. Menu → « Installer le micro Micara… », puis réessayez.")
            return
        } catch {
            alert("Micro Micara", "Impossible de préparer le micro : \(error)")
            return
        }

        // 2. Moteur audio : micro du Mac + téléphones → BlackHole.
        let engine = AudioEngine()
        engine.mode = Settings.mixMode
        engine.phonesMuted = muted
        engine.onLevel = { [weak self] level in self?.bar.setLevel(level) }
        do {
            try engine.start(outputDeviceUID: MicaraAggregate.blackHoleUID)
        } catch {
            inputSwitcher.restore()
            alert("Audio", "Impossible de démarrer le moteur audio : \(error)")
            return
        }
        audio = engine

        // 3. Signal : les téléphones se connectent par le code du QR.
        let client = SignalClient(config: SignalConfig(serverURL: Account.serverURL, token: token), audio: engine)
        client.onPhones = { [weak self] dots in self?.bar.setPhones(dots) }
        client.onState = { [weak self] state in self?.signalDidChange(state) }
        client.connect()
        signal = client

        // 4. Ce qui se voit.
        phase = .meeting
        Settings.meetingsStarted += 1
        bar.setJoinURL(joinURL)
        bar.setMuted(muted)
        bar.setPhones([])
        borders.show()
        bar.show()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Account.heartbeat(state: "active") }
        Account.heartbeat(state: "active")
        refreshMenuState()
        AppLog.write("réunion démarrée")
    }

    private func endMeeting() {
        guard phase == .meeting else { return }
        phase = .idle
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        signal?.disconnect(); signal = nil
        audio?.stop(); audio = nil
        bar.hide()
        borders.hide()
        // Le micro par défaut revient à ce qu'il était : l'utilisateur retrouve
        // son Mac tel qu'il l'a laissé.
        inputSwitcher.restore()
        Account.heartbeat(state: "sleep")
        refreshMenuState()
        AppLog.write("réunion terminée")
    }

    private func signalDidChange(_ state: SignalClient.State) {
        switch state {
        case .connecting: AppLog.write("signal : connexion…")
        case .connected: AppLog.write("signal : connecté")
        case .disconnected(let code, let reason):
            AppLog.write("signal : déconnecté \(code.map(String.init) ?? "-") \(reason ?? "")")
            if let code, let text = CloseCode.describe(code), [4001, 4003, 4005, 4006, 4007].contains(code) {
                // Fatal : le jeton ou l'espace ne valent plus rien. On termine
                // la réunion proprement plutôt que de laisser un micro muet.
                endMeeting()
                if code == 4001 {
                    // Jeton révoqué côté serveur : on repart de zéro à la prochaine réunion.
                    Account.token = nil
                    Account.code = nil
                    register()
                }
                alert("Réunion interrompue", text)
            }
        }
    }

    // MARK: BarDelegate

    func barDidToggleMute() { toggleMute() }
    func barDidEnd() { endMeeting() }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { refreshMenuState() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
