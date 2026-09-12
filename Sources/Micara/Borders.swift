import AppKit
import QuartzCore

// MARK: - Screen border

/// Blue ring around a screen. Purely decorative: the window carrying it lets
/// every click through.
private final class BorderView: NSView {
    private let ring = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        // A FILLED ring, not a stroke. A stroke is centred on its path, so
        // both its edges share one radius; rounding the outer edge leaves a gap
        // in the square bottom corners of the screen.
        ring.fillColor = Style.accent.cgColor
        ring.fillRule = .evenOdd
        ring.strokeColor = nil
        ring.shadowColor = Style.accent.cgColor
        ring.shadowOpacity = 0.6
        ring.shadowRadius = 8
        ring.shadowOffset = .zero
        ring.opacity = Style.borderOpacity
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = Style.borderWidth
        let path = CGMutablePath()
        path.addRect(bounds)                                     // outer: square
        path.addPath(CGPath(roundedRect: bounds.insetBy(dx: w, dy: w),
                            cornerWidth: Style.borderInnerRadius,
                            cornerHeight: Style.borderInnerRadius,
                            transform: nil))                     // inner: rounded
        ring.frame = bounds
        ring.path = path
    }
}

/// The border, one window per screen.
///
/// Differences from Eyesaver: accent colour, fixed opacity (a meeting lasts a
/// long time, a pulse would become torture) and half the thickness.
final class Borders {
    private var windows: [NSWindow] = []
    private(set) var visible = false
    private var screenObserver: NSObjectProtocol?

    init() {
        // A display plugged or unplugged mid-meeting must not leave a bare
        // screen: we rebuild identically.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func show() {
        guard !visible else { return }
        visible = true
        build(fading: true)
    }

    func hide() {
        guard visible else { return }
        visible = false
        let leaving = windows
        windows.removeAll()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Style.borderFade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            leaving.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { leaving.forEach { $0.orderOut(nil) } })
    }

    /// Rebuilds one window per screen after a layout change. No fade: this is
    /// a replacement, not an appearance.
    private func rebuild() {
        guard visible else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        build(fading: false)
    }

    private func build(fading: Bool) {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false, screen: screen)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            // Click-through: the border must never get in the way of work.
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                         .fullScreenAuxiliary, .ignoresCycle]
            window.setFrame(screen.frame, display: true)
            let view = BorderView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            window.alphaValue = fading ? 0 : 1
            window.orderFrontRegardless()
            windows.append(window)
        }
        guard fading else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Style.borderFade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            windows.forEach { $0.animator().alphaValue = 1 }
        }
    }
}
