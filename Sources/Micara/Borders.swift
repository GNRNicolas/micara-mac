import AppKit
import QuartzCore

// MARK: - Liseré d'écran

/// Anneau bleu autour d'un écran. Purement décoratif : la fenêtre qui le porte
/// laisse passer tous les clics.
private final class BorderView: NSView {
    private let ring = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        // Un anneau REMPLI, pas un trait. Un trait est centré sur son tracé,
        // donc ses deux bords partagent un même rayon ; arrondir le bord
        // extérieur laisse un vide dans les coins bas carrés de l'écran.
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
        path.addRect(bounds)                                     // extérieur : carré
        path.addPath(CGPath(roundedRect: bounds.insetBy(dx: w, dy: w),
                            cornerWidth: Style.borderInnerRadius,
                            cornerHeight: Style.borderInnerRadius,
                            transform: nil))                     // intérieur : arrondi
        ring.frame = bounds
        ring.path = path
    }
}

/// Le liseré, une fenêtre par écran.
///
/// Différences avec Eyesaver : couleur d'accent, opacité fixe (une réunion dure
/// longtemps, une pulsation deviendrait un supplice) et épaisseur moitié.
final class Borders {
    private var windows: [NSWindow] = []
    private(set) var visible = false
    private var screenObserver: NSObjectProtocol?

    init() {
        // Un écran branché ou débranché pendant la réunion ne doit pas laisser
        // un écran nu : on reconstruit à l'identique.
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

    /// Refait une fenêtre par écran après un changement d'agencement. Sans
    /// fondu : c'est un remplacement, pas une apparition.
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
            // Click-through : le liseré ne doit jamais gêner le travail.
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
