import AppKit
import ServiceManagement
import MicaraCore

// Micara for Mac — the computer and the phones in the room merge their audio
// into a single "Micara" microphone that Teams/Zoom see as an ordinary one.
// Shape borrowed from Eyesaver: menu bar, no Dock, a non-activating bar at the
// bottom of the screen, a border around every display.
//
// Cycle: `idle` ⇄ `meeting`. Everything goes through `startMeeting()` and
// `endMeeting()`.

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

    private let meetingItem = NSMenuItem(title: "Start a Meeting", action: #selector(toggleMeeting), keyEquivalent: "")
    private let muteItem = NSMenuItem(title: "Mute Phones", action: #selector(toggleMute), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
    private let micItem = NSMenuItem(title: "Reinstall the Micara Microphone", action: #selector(reinstallMic), keyEquivalent: "")
    private let autoUpdateItem = NSMenuItem(title: "Check for Updates Automatically", action: #selector(toggleAutoUpdate), keyEquivalent: "")
    private var diagnosticsTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("--- launch \(Updater.currentVersion) ---")
        guard !quitIfAlreadyRunning() else { return }
        buildMenu()
        installTestHooks()
        register()

        // Open at Login on by default on first install: the app is meant to be
        // forgotten in the menu bar. Switchable from the menu.
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
        // Quitting mid-meeting must not leave Teams on a ghost microphone.
        if phase == .meeting { endMeeting() }
    }

    /// Two copies = two icons, two bars, and the microphone forced twice.
    private func quitIfAlreadyRunning() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { $0 != .current }
        guard let first = others.first else { return false }
        AppLog.write("already running (pid \(first.processIdentifier)); this copy quits")
        NSApp.terminate(nil)
        return true
    }

    /// `kill -USR1 <pid>` starts/ends a meeting: a test loop without going
    /// through the menu.
    private func installTestHooks() {
        Darwin.signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.toggleMeeting() }
        source.resume()
        signalSources.append(source)
    }

    // MARK: Registration

    private func register() {
        Account.ensureRegistered { [weak self] result in
            switch result {
            case .success: self?.refreshMenuState()
            case .failure(let error):
                AppLog.write("registration: \(error.localizedDescription)")
                // Quiet retry: the Mac may have just woken up without network.
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self?.register() }
            }
        }
    }

    // MARK: Menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = statusImage()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(meetingItem)
        menu.addItem(muteItem)
        menu.addItem(.separator())
        menu.addItem(choiceMenu("Mixing", choices: [("Dominance + gate", 0), ("Sum", 1)],
                                selected: Settings.mixMode == .dominance ? 0 : 1, action: #selector(pickMixMode(_:))))
        menu.addItem(loginItem)
        menu.addItem(micItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(autoUpdateItem)
        menu.addItem(menuItem("Share Micara", #selector(shareApp)))
        menu.addItem(menuItem("Star on GitHub", #selector(openRepository)))
        menu.addItem(.separator())
        menu.items.forEach { if $0.action != nil { $0.target = self } }
        menu.addItem(NSMenuItem(title: "Quit Micara", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
        refreshMenuState()
    }

    /// The Micara logo (the dot grid from the brand SVG) drawn as a *template*
    /// image: macOS tints it itself to match the menu bar (light, dark, vivid
    /// wallpaper). A fixed grey PNG stayed grey everywhere, unreadable on a
    /// light bar.
    private func statusImage() -> NSImage {
        let side: CGFloat = 22
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            // Coordinates from logo.svg (viewBox 64), radius 3.44.
            let dots: [(CGFloat, CGFloat)] = [
                (22.29, 17.60), (41.08, 17.60), (31.69, 26.99), (13.52, 36.38), (13.52, 46.40),
                (13.52, 26.99), (22.29, 26.99), (41.08, 26.99), (50.48, 26.99), (50.48, 36.38),
                (50.48, 46.40), (31.69, 37.01),
            ]
            let scale = rect.width / 64
            let r = 3.44 * scale * 1.1  // slightly bolder than the SVG: 22 pt, not 64
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
        meetingItem.title = inMeeting ? "End the Meeting" : "Start a Meeting"
        meetingItem.isEnabled = Account.isRegistered || inMeeting
        muteItem.isEnabled = inMeeting
        muteItem.title = muted ? "Unmute Phones" : "Mute Phones"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        autoUpdateItem.state = Updater.automatic ? .on : .off
        micItem.title = MicaraAggregate.blackHoleInstalled ? "Reinstall the Micara Microphone" : "Install the Micara Microphone…"
    }

    // MARK: Menu actions

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
        AppLog.write(muted ? "phones muted" : "phones unmuted")
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
            AppLog.write("open at login: \(error.localizedDescription)")
        }
        refreshMenuState()
    }

    /// BlackHole is a system driver: only its installer (admin password) can
    /// put it in place. Open the bundled .pkg in Installer.app.
    @objc private func reinstallMic() {
        if MicaraAggregate.blackHoleInstalled {
            do {
                try MicaraAggregate.remove()
                try MicaraAggregate.ensure()
                AppLog.write("Micara aggregate recreated")
            } catch {
                alert("Micara Microphone", "Could not recreate the microphone: \(error)")
            }
            return
        }
        guard let pkg = Bundle.main.url(forResource: "BlackHole16ch-0.7.1", withExtension: "pkg") else {
            alert("Micara Microphone", "The BlackHole installer is missing from the app. Run ./build.sh --install again from the Terminal.")
            return
        }
        NSWorkspace.shared.open(pkg)
    }

    @objc private func checkForUpdates() { Updater.check(manual: true) }
    @objc private func toggleAutoUpdate() { Updater.automatic.toggle(); refreshMenuState() }
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

    // MARK: Meeting

    private func startMeeting() {
        guard phase == .idle, let token = Account.token, let joinURL = Account.joinURL else { return }

        // 1. The "Micara" microphone (an aggregate around BlackHole) exists.
        //    Without BlackHole, nothing can work. The user's real mic is noted
        //    NOW, before anything changes the default: it is the one the engine
        //    must capture, never whatever device happens to come first in the
        //    list (the first test picked a Bluetooth speaker's mic).
        let realMic = AudioDevices.defaultInputUID()
        do {
            try MicaraAggregate.ensure()
        } catch AudioDeviceError.blackHoleMissing {
            alert("Micara Microphone Missing", "BlackHole is not installed. Menu → \"Install the Micara Microphone…\", then try again.")
            return
        } catch {
            alert("Micara Microphone", "Could not prepare the microphone: \(error)")
            return
        }

        // 2. Micara becomes the default input FIRST. AVAudioEngine stops itself
        //    on any default-device change (see `AudioEngine.rebuildEngines`),
        //    so the switch happens before the engines exist rather than under
        //    them. The real mic was noted above and is passed explicitly.
        do { try inputSwitcher.activate() } catch {
            alert("Micara Microphone", "Could not select the Micara microphone: \(error)")
            return
        }

        // 3. Audio engine: the Mac's microphone + the phones → BlackHole.
        let engine = AudioEngine()
        engine.mode = Settings.mixMode
        engine.phonesMuted = muted
        engine.onLevel = { [weak self] level in self?.bar.setLevel(level) }
        do {
            try engine.start(outputDeviceUID: MicaraAggregate.blackHoleUID, inputDeviceUID: realMic)
        } catch {
            inputSwitcher.restore()
            alert("Audio", "Could not start the audio engine: \(error)")
            return
        }
        audio = engine

        // 4. Signal: phones join through the code in the QR.
        let client = SignalClient(config: SignalConfig(serverURL: Account.serverURL, token: token), audio: engine)
        client.onPhones = { [weak self] dots in self?.bar.setPhones(dots) }
        client.onState = { [weak self] state in self?.signalDidChange(state) }
        client.connect()
        signal = client

        // 5. What is visible.
        phase = .meeting
        Settings.meetingsStarted += 1
        bar.setJoinURL(joinURL)
        bar.setMuted(muted)
        bar.setPhones([])
        borders.show()
        bar.show()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Account.heartbeat(state: "active") }
        // What is actually flowing, for the log: buffers received and peak per
        // channel, blocks rendered. Tells "nothing arrives" from "arrives muted".
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, let audio = self.audio else { return }
            let channels = audio.diagnostics().sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.buffers) buf, peak \(String(format: "%.3f", $0.value.peak))" }
                .joined(separator: " | ")
            AppLog.write("[audio] rendered \(audio.renderedBlocks) blocks | \(channels)")
        }
        Account.heartbeat(state: "active")
        refreshMenuState()
        AppLog.write("meeting started")
    }

    private func endMeeting() {
        guard phase == .meeting else { return }
        phase = .idle
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        diagnosticsTimer?.invalidate(); diagnosticsTimer = nil
        signal?.disconnect(); signal = nil
        audio?.stop(); audio = nil
        bar.hide()
        borders.hide()
        // The default microphone goes back to what it was: the user finds the
        // Mac as they left it.
        inputSwitcher.restore()
        Account.heartbeat(state: "sleep")
        refreshMenuState()
        AppLog.write("meeting ended")
    }

    private func signalDidChange(_ state: SignalClient.State) {
        switch state {
        case .connecting: AppLog.write("signal: connecting…")
        case .connected: AppLog.write("signal: connected")
        case .disconnected(let code, let reason):
            AppLog.write("signal: disconnected \(code.map(String.init) ?? "-") \(reason ?? "")")
            if let code, let text = CloseCode.describe(code), [4001, 4003, 4005, 4006, 4007].contains(code) {
                // Fatal: the token or the space is worthless now. End the
                // meeting cleanly rather than leave a mute microphone behind.
                endMeeting()
                if code == 4001 {
                    // Token revoked server-side: start over at the next meeting.
                    Account.token = nil
                    Account.code = nil
                    register()
                }
                alert("Meeting Interrupted", text)
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
