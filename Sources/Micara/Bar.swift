import AppKit
import QuartzCore

import MicaraCore

// MARK: - Bar

protocol BarDelegate: AnyObject {
    func barDidToggleMute()
    func barDidEnd()
}

/// Dark translucent pill, parked at the bottom-left of the main screen, with
/// the meeting's QR unfolding above it. Non-activating panel: clicking it never
/// steals focus from the video-call app.
///
/// Its width is CONSTANT for the whole meeting: every element reserves its
/// widest footprint. Nothing that happens during a meeting (a phone joining,
/// the mic muted) may make the bar move.
final class Bar {
    private weak var delegate: BarDelegate?

    private let icon = NSImageView()
    private let meter = LevelMeter()
    private let qrToggle = QRToggle()
    private let dots = PhoneDotsView()
    private lazy var muteButton = PillButton(labels: ["Mute", "Unmute"], prominent: false,
                                             target: self, action: #selector(toggleMute))
    private lazy var endButton = PillButton(labels: ["End"], prominent: true,
                                            target: self, action: #selector(end))
    /// Sends the bar to the left edge. Last in the row, so it reads as "push
    /// all of this out of the way" rather than as one more meeting control.
    private lazy var collapseButton = PillButton(symbol: "chevron.left",
                                                 accessibility: "Collapse the bar",
                                                 target: self, action: #selector(collapse))
    /// The whole content of the collapsed tab.
    private lazy var expandButton = PillButton(symbol: "chevron.right",
                                               accessibility: "Expand the bar",
                                               target: self, action: #selector(expand))
    /// The expanded row, kept so its width can be frozen and its alpha animated.
    private var row = NSStackView()
    /// Width of the expanded pill, measured once. The row is pinned by its
    /// leading edge only, so the window can narrow without the stack reflowing
    /// and squashing its content mid-animation.
    private var expandedWidth: CGFloat = 0

    private lazy var pill: PillBackground = buildPill()
    private lazy var panel: NSPanel = buildPanel()

    private let qrView = QRCodeView()
    /// Saves the meeting's QR onto the printable card. Sits in the panel's top
    /// padding; its own tracking area does not cancel the panel's, so hovering
    /// it keeps the panel open.
    private lazy var downloadButton = PillButton(symbol: "arrow.down.circle",
                                                 accessibility: "Download the QR card",
                                                 pointSize: 14,
                                                 box: NSSize(width: Style.qrPadding, height: Style.qrPadding),
                                                 target: self, action: #selector(exportCardAction))
    /// The URL the QR currently encodes. Kept so the card can be rendered
    /// without going back through the view.
    private(set) var joinURL: URL?
    private lazy var qrPill: HoverPanelView = buildQRPill()
    private lazy var qrPanel: NSPanel = buildQRPanel()

    private var muted = false
    private var qrShown = false
    private var overToggle = false
    private var overQR = false
    private var hoverWork: DispatchWorkItem?

    /// Received value and displayed value: the smoothing happens between the two.
    private var targetLevel: CGFloat = 0
    private var shownLevel: CGFloat = 0
    private var meterTimer: Timer?

    private(set) var isVisible = false
    /// The QR stays unfolded after a click on the icon, so people can scan
    /// without the mouse having to sit on it.
    private(set) var isQRPinned = false
    /// Folded away against the left edge. Per meeting, never persisted:
    /// `show()` always starts expanded, because a bar nobody can see is a bar
    /// nobody remembers hiding.
    private(set) var isCollapsed = false

    init(delegate: BarDelegate) {
        self.delegate = delegate
    }

    // MARK: Construction

    private func buildPill() -> PillBackground {
        let pill = PillBackground()

        applyMicSymbol()
        icon.imageScaling = .scaleNone

        qrToggle.onHoverChange = { [weak self] inside in
            self?.overToggle = inside
            self?.hoverChanged()
        }
        qrToggle.onClick = { [weak self] in self?.togglePin() }

        for view in [icon, meter, qrToggle, dots] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        row = NSStackView(views: [icon, meter, qrToggle, dots, muteButton, endButton, collapseButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.setCustomSpacing(12, after: dots)
        row.setCustomSpacing(6, after: endButton)
        row.edgeInsets = NSEdgeInsets(top: 0, left: Style.pillLeftInset,
                                      bottom: 0, right: Style.pillRightInset)
        row.translatesAutoresizingMaskIntoConstraints = false
        expandedWidth = row.fittingSize.width.rounded()

        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.isHidden = true

        pill.addSubview(row)
        pill.addSubview(expandButton)
        NSLayoutConstraint.activate([
            // Leading edge and a frozen width, NOT both edges: when the window
            // shrinks to the tab, the row has to slide out of view untouched.
            // Pinned to the trailing edge it would compress instead, and the
            // buttons would visibly squash on their way out.
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            row.topAnchor.constraint(equalTo: pill.topAnchor),
            row.widthAnchor.constraint(equalToConstant: expandedWidth),
            row.heightAnchor.constraint(equalToConstant: Style.pillHeight),

            expandButton.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            expandButton.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        return pill
    }

    private func buildPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: Style.pillHeight),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        configure(panel)
        panel.contentView = pill
        return panel
    }

    private func buildQRPill() -> HoverPanelView {
        let view = HoverPanelView()
        view.onHoverChange = { [weak self] inside in
            self?.overQR = inside
            self?.hoverChanged()
        }

        let caption = NSTextField(labelWithString: "Scan to join")
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = Style.ink.withAlphaComponent(0.6)
        caption.alignment = .left

        for sub in [qrView, caption, downloadButton] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            qrView.topAnchor.constraint(equalTo: view.topAnchor, constant: Style.qrPadding),
            qrView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Style.qrPadding),
            qrView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Style.qrPadding),
            qrView.heightAnchor.constraint(equalTo: qrView.widthAnchor),

            // One footer row under the QR: caption on the left, download on
            // the right, both aligned on the QR's own edges.
            caption.topAnchor.constraint(equalTo: qrView.bottomAnchor, constant: 10),
            caption.leadingAnchor.constraint(equalTo: qrView.leadingAnchor),
            caption.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            downloadButton.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            downloadButton.trailingAnchor.constraint(equalTo: qrView.trailingAnchor),
            downloadButton.leadingAnchor.constraint(greaterThanOrEqualTo: caption.trailingAnchor, constant: 8),
        ])
        return view
    }

    private func buildQRPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 240),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        configure(panel)
        // Transparent container: it is the pill inside that gets scaled, not
        // the window — resizing the window would rerun layout and smear the QR.
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        qrPill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(qrPill)
        NSLayoutConstraint.activate([
            qrPill.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            qrPill.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            qrPill.topAnchor.constraint(equalTo: container.topAnchor),
            qrPill.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        return panel
    }

    private func configure(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        // Always dark, whatever the system theme.
        panel.appearance = NSAppearance(named: .vibrantDark)
        // ARC owns the panel: it dies with its Bar, never through close().
        panel.isReleasedWhenClosed = false
    }

    /// Whether the window server is actually compositing the bar — judged
    /// from OUTSIDE the process. `NSWindow.isVisible` answers true for a
    /// window the compositor has dropped (a panel reused for hours across
    /// Spaces and full-screen apps ends up there: alpha 1, not on screen —
    /// Eyesaver, 13/09), and that gap is precisely the bug. Only the app's
    /// own windows are readable without the Screen Recording permission,
    /// which is all this needs.
    var isComposited: Bool {
        guard isVisible else { return false }
        let number = UInt32(panel.windowNumber)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowNumber as String] as? UInt32) == number }
    }

    /// The Micara logo (the dot grid on its yellow tile), drawn rather than
    /// loaded: no asset to ship, crisp at any scale. Muted dims it.
    private func applyMicSymbol() {
        icon.image = Bar.logoImage(side: Style.iconBox)
        icon.alphaValue = muted ? 0.4 : 1
    }

    static func logoImage(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            // Coordinates from the brand SVG (viewBox 64).
            let dots: [(CGFloat, CGFloat)] = [
                (22.29, 17.60), (41.08, 17.60), (31.69, 26.99), (13.52, 36.38), (13.52, 46.40),
                (13.52, 26.99), (22.29, 26.99), (41.08, 26.99), (50.48, 26.99), (50.48, 36.38),
                (50.48, 46.40), (31.69, 37.01),
            ]
            let scale = rect.width / 64
            Style.brandYellow.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2 * scale, dy: 2 * scale),
                         xRadius: 14 * scale, yRadius: 14 * scale).fill()
            Style.brandInk.setFill()
            let r = 3.44 * scale
            for (x, y) in dots {
                NSBezierPath(ovalIn: NSRect(x: x * scale - r, y: y * scale - r, width: 2 * r, height: 2 * r)).fill()
            }
            return true
        }
    }

    // MARK: Actions

    @objc private func toggleMute() { delegate?.barDidToggleMute() }
    @objc private func end() { delegate?.barDidEnd() }
    @objc private func collapse() { setCollapsed(true, animated: true) }
    @objc private func expand() { setCollapsed(false, animated: true) }

    @objc private func exportCardAction() {
        guard let url = exportCard() else { return }
        // Revealing beats opening: people want to drag the card into a chat or
        // a slide deck, not look at it in Preview.
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: API

    func show() {
        // The flag alone is not trusted: if a hide() completion fired after a
        // show() (see `hide`), the panel is off screen with `isVisible` true,
        // and a flag-only guard would keep it off for the whole meeting.
        // Measured on 13/09 with `CGWindowListCopyWindowInfo`: bar 443x60,
        // alpha 1, onscreen no, after End then Start 50 ms apart.
        guard !isVisible || !panel.isVisible else { return }
        isVisible = true
        // A new meeting always starts with the bar out in the open.
        applyCollapsed(false)
        reposition(animated: false)
        let destination = targetFrame()
        panel.alphaValue = 0
        // Slide up from below, like Eyesaver.
        panel.setFrame(destination.offsetBy(dx: 0, dy: -12), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Style.appearDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(destination, display: true)
        }
        startMeter()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        isQRPinned = false
        qrToggle.pinned = false
        hideQR(animated: false)
        stopMeter()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Style.disappearDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [self] in
            // This block runs in a future where its decision may be stale: a
            // show() may have happened during the fade. Revalidate, do not
            // apply.
            guard !isVisible else { return }
            panel.orderOut(nil)
        })
    }

    /// Mix level, 0…1, received ~20 times a second. Only the target moves here:
    /// the display catches up in `tick`, otherwise the gauge jumps on every packet.
    func setLevel(_ level: Float) {
        targetLevel = CGFloat(min(1, max(0, level)))
    }

    /// No window recompute: the dot area is already at its maximum size, the
    /// circles merely light up inside it.
    func setPhones(_ dots: [PhoneDot]) {
        self.dots.set(Array(dots.prefix(Style.maxPhones)))
    }

    func setMuted(_ muted: Bool) {
        guard muted != self.muted else { return }
        self.muted = muted
        muteButton.update(label: muted ? "Unmute" : "Mute")
        muteButton.tinted = muted
        applyMicSymbol()
        meter.dimmed = muted
    }

    func setJoinURL(_ url: URL) {
        joinURL = url
        qrView.setURL(url)
        qrPill.layoutSubtreeIfNeeded()
        positionQR()
    }

    /// Folds the bar away against the left edge, or brings it back.
    ///
    /// `setLevel`, `setPhones` and `setMuted` keep working while collapsed:
    /// they only touch views, which stay alive behind the tab and are already
    /// up to date when it opens again.
    func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard collapsed != isCollapsed else { return }
        guard animated, isVisible else { return applyCollapsed(collapsed) }

        isCollapsed = collapsed
        if collapsed {
            // The QR cannot outlive the pill it points at.
            isQRPinned = false
            qrToggle.pinned = false
            hideQR(animated: true)
        }
        // The corner style flips at the start of the motion rather than at the
        // end: a 16 pt corner squaring off on an element that is already
        // sliding goes unnoticed, whereas the same change on a tab standing
        // still reads as a pop.
        pill.corners = collapsed ? .rightOnly : .all

        let destination = targetFrame()
        if collapsed {
            expandButton.isHidden = false
            expandButton.alphaValue = 0
        } else {
            row.isHidden = false
            row.alphaValue = 0
        }
        // One animation group: the window travels and the content cross-fades
        // on the same clock, so there is no seam between the two.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Style.appearDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(destination, display: true)
            row.animator().alphaValue = collapsed ? 0 : 1
            expandButton.animator().alphaValue = collapsed ? 1 : 0
        }, completionHandler: { [self] in
            guard isCollapsed == collapsed else { return }
            row.isHidden = collapsed
            expandButton.isHidden = !collapsed
            // The shadow is cached from the previous shape; without this the
            // tab keeps the pill's shadow for a beat.
            panel.invalidateShadow()
            if !collapsed { positionQR() }
        })
    }

    /// The same change without any animation, used by `show()` and by the
    /// non-animated path of `setCollapsed`.
    private func applyCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        if collapsed {
            isQRPinned = false
            qrToggle.pinned = false
            hideQR(animated: false)
        }
        pill.corners = collapsed ? .rightOnly : .all
        row.isHidden = collapsed
        row.alphaValue = collapsed ? 0 : 1
        expandButton.isHidden = !collapsed
        expandButton.alphaValue = collapsed ? 1 : 0
        if isVisible {
            panel.setFrame(targetFrame(), display: true)
            panel.invalidateShadow()
            positionQR()
        }
    }

    // MARK: Level meter

    private func startMeter() {
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        // `.common`: otherwise the gauge freezes as soon as a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        shownLevel = 0
        targetLevel = 0
        meter.level = 0
    }

    /// Fast rise, slow fall: a soft attack misses syllables, and a fast fall
    /// makes the gauge flicker between words.
    private func tick() {
        let coefficient: CGFloat = targetLevel > shownLevel ? 0.45 : 0.10
        shownLevel += (targetLevel - shownLevel) * coefficient
        if abs(shownLevel - targetLevel) < 0.002 { shownLevel = targetLevel }
        meter.level = shownLevel
    }

    // MARK: Hover, pinning and QR

    /// Pins the QR panel open (the click on the QR icon, without the click).
    /// For the screenshots in the README: see `installTestHooks`.
    func pinQR() {
        guard !isQRPinned else { return }
        togglePin()
    }

    private func togglePin() {
        isQRPinned.toggle()
        qrToggle.pinned = isQRPinned
        if isQRPinned {
            showQR()
        } else if !overToggle && !overQR {
            hideQR(animated: true)
        }
    }

    private func hoverChanged() {
        hoverWork?.cancel()
        if overToggle || overQR {
            showQR()
        } else if !isQRPinned {
            // Small delay: the trip from the icon to the QR crosses a gap of a
            // few points, and without this the panel would flicker.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.overToggle, !self.overQR, !self.isQRPinned else { return }
                self.hideQR(animated: true)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Style.hoverGrace, execute: work)
        }
    }

    private func showQR() {
        // Collapsed, there is nothing for the panel to hang off.
        // Same belt as `show()`: the flag is not enough if the panel is gone.
        guard isVisible, !isCollapsed, !(qrShown && qrPanel.isVisible) else { return }
        qrShown = true
        qrPill.layoutSubtreeIfNeeded()
        positionQR()
        qrPanel.alphaValue = 0
        panel.addChildWindow(qrPanel, ordered: .above)
        qrPanel.orderFrontRegardless()

        setQRScale(0.9)
        let destination = qrPanel.frame
        qrPanel.setFrame(destination.offsetBy(dx: 0, dy: -6), display: false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Style.appearDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            qrPanel.animator().alphaValue = 1
            qrPanel.animator().setFrame(destination, display: true)
            animateQRScale(to: 1, duration: Style.appearDuration)
        }, completionHandler: { [self] in qrPanel.invalidateShadow() })
    }

    private func hideQR(animated: Bool) {
        guard qrShown else { return }
        qrShown = false
        guard animated else {
            panel.removeChildWindow(qrPanel)
            qrPanel.orderOut(nil)
            return
        }
        animateQRScale(to: 0.94, duration: Style.disappearDuration)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Style.disappearDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            qrPanel.animator().alphaValue = 0
        }, completionHandler: { [self] in
            guard !qrShown else { return }
            panel.removeChildWindow(qrPanel)
            qrPanel.orderOut(nil)
        })
    }

    /// Scaling around the centre without touching `anchorPoint`: AppKit resets
    /// it on every layout pass, whereas the manual composition survives.
    private func centeredScale(_ scale: CGFloat) -> CATransform3D {
        guard let layer = qrPill.layer else { return CATransform3DIdentity }
        let anchor = layer.anchorPoint
        let dx = (0.5 - anchor.x) * qrPill.bounds.width
        let dy = (0.5 - anchor.y) * qrPill.bounds.height
        var t = CATransform3DMakeTranslation(dx, dy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -dx, -dy, 0)
    }

    private func setQRScale(_ scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        qrPill.layer?.transform = centeredScale(scale)
        CATransaction.commit()
    }

    private func animateQRScale(to scale: CGFloat, duration: TimeInterval) {
        guard let layer = qrPill.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.transform ?? layer.transform
        animation.toValue = centeredScale(scale)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        setQRScale(scale)
        layer.add(animation, forKey: "scale")
    }

    /// Centred above the pill, as the pill is on the screen; clamped to the
    /// margins so it never overflows.
    private func positionQR() {
        let size = qrPill.fittingSize
        let pillFrame = panel.frame
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let centered = pillFrame.midX - size.width / 2
        let x = min(max(area.minX + Style.barMargin, centered),
                    area.maxX - size.width - Style.barMargin)
        qrPanel.setFrame(NSRect(x: x.rounded(),
                                y: pillFrame.maxY + Style.qrGap,
                                width: size.width.rounded(),
                                height: size.height.rounded()),
                         display: false)
    }

    // MARK: Position

    private func reposition(animated: Bool) {
        pill.layoutSubtreeIfNeeded()
        let destination = targetFrame()
        if animated && isVisible {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(destination, display: true)
            }, completionHandler: { [self] in positionQR() })
        } else {
            panel.setFrame(destination, display: true)
            positionQR()
        }
    }

    /// Centred at the bottom of the screen, like Eyesaver. Nicolas's call
    /// (12/09): a corner does not work with a Dock on the left or at the bottom,
    /// the centre is neutral. `visibleFrame`: at `.screenSaver` level the bar
    /// would sit over the Dock if we started from the physical edge (measured:
    /// 44 pt of overlap). Dock hidden → it drops flush with the edge.
    ///
    /// The width comes from `fittingSize`, but it is constant: every element
    /// has a frozen width.
    private func targetFrame() -> NSRect {
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let y = (area.minY + Style.barMargin).rounded()
        // Collapsed: flush against the usable left edge, no margin at all —
        // the tab is meant to look like it is hanging off the screen.
        if isCollapsed {
            return NSRect(x: area.minX.rounded(), y: y,
                          width: Style.tabWidth, height: Style.pillHeight)
        }
        return NSRect(x: (area.midX - expandedWidth / 2).rounded(), y: y,
                      width: expandedWidth, height: Style.pillHeight)
    }
}
