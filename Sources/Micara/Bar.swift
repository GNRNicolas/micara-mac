import AppKit
import CoreImage
import QuartzCore

import MicaraCore

// MARK: - Fond du pill

/// Matériau translucide réellement découpé en coins arrondis.
///
/// `layer.cornerRadius` ne suffit pas : en mélange `.behindWindow`, le flou est
/// composité par le serveur de fenêtres sur tout le rectangle de la vue et
/// ignore le masque de calque — d'où la boîte visible autour du pill.
/// `maskImage` est le seul découpage que la composition respecte, et l'ombre de
/// la fenêtre le suit.
class PillBackground: NSVisualEffectView {
    private let outline = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        outline.fillColor = nil
        outline.strokeColor = Style.ink.withAlphaComponent(0.14).cgColor
        outline.lineWidth = 1
        layer?.addSublayer(outline)
        maskImage = PillBackground.mask(radius: Style.pillRadius)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Le filet fin doit être un `CAShapeLayer` à part : `layer.borderWidth`
        // resterait rectangulaire, le masque ne s'y applique pas.
        outline.frame = bounds
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                              cornerWidth: Style.pillRadius,
                              cornerHeight: Style.pillRadius,
                              transform: nil)
    }

    /// Image étirable : les quatre coins sont préservés, le centre s'étire.
    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // Le noir est ici une opacité, pas une couleur : c'est un masque.
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Une vue de fond qui sait dire quand la souris entre et sort. Sert au
/// panneau QR : sans ça, aller de l'icône au panneau le replierait.
private final class HoverPanelView: PillBackground {
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

// MARK: - Bouton du pill

/// Capsule du pill. Deux styles, ceux d'Eyesaver : principal (aplat `ink`,
/// texte `night`) et secondaire (encre translucide). Aucune autre couleur.
final class PillButton: NSButton {
    /// Tous les libellés que ce bouton pourra porter. La largeur est celle du
    /// plus long : un bouton qui change de texte ne doit pas changer de taille,
    /// sinon tout le pill respire à chaque mute et l'œil suit le mouvement.
    private let candidates: [String]
    private var label: String
    private let prominent: Bool
    private var hovered = false
    /// Marque le bouton secondaire quand le micro est coupé. En encre, pas en
    /// couleur : la barre n'a pas de teinte à elle.
    var tinted = false { didSet { attributedTitle = makeTitle(); paint() } }

    init(labels: [String], prominent: Bool, target: AnyObject, action: Selector) {
        self.candidates = labels
        self.label = labels[0]
        self.prominent = prominent
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.masksToBounds = true
        attributedTitle = makeTitle()
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(label newLabel: String) {
        guard newLabel != label else { return }
        label = newLabel
        attributedTitle = makeTitle()
    }

    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    private func makeTitle() -> NSAttributedString {
        let tint: NSColor = prominent
            ? Style.night
            : Style.ink.withAlphaComponent(tinted ? 1.0 : 0.92)
        return NSAttributedString(string: label, attributes: [
            .font: PillButton.font,
            .foregroundColor: tint,
        ])
    }

    /// Largeur figée une fois pour toutes, sur le plus long libellé possible.
    override var intrinsicContentSize: NSSize {
        let widest = candidates
            .map { NSAttributedString(string: $0, attributes: [.font: PillButton.font]).size().width }
            .max() ?? 0
        return NSSize(width: (widest + 26).rounded(.up), height: 30)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 9
    }

    private func paint() {
        let fill: NSColor
        if prominent {
            fill = hovered ? Style.ink : Style.ink.withAlphaComponent(0.88)
        } else {
            fill = Style.ink.withAlphaComponent(tinted ? (hovered ? 0.26 : 0.20)
                                                       : (hovered ? 0.16 : 0.09))
        }
        layer?.backgroundColor = fill.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; paint() }
    override func mouseExited(with event: NSEvent) { hovered = false; paint() }
}

// MARK: - Icône QR

/// L'icône qui déplie le QR : survol pour un coup d'œil, clic pour l'épingler
/// le temps que les gens rejoignent.
private final class QRToggle: NSImageView {
    var onHoverChange: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private var hovered = false
    var pinned = false { didSet { paint() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "qrcode", accessibilityDescription: "QR de la réunion")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        imageScaling = .scaleNone
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Style.iconBox, height: Style.iconBox)
    }

    private func paint() {
        let alpha: CGFloat = pinned ? 1.0 : (hovered ? 0.85 : 0.55)
        contentTintColor = Style.ink.withAlphaComponent(alpha)
    }

    // L'app n'est jamais active : sans ça, le premier clic serait consommé
    // pour la « réveiller » et n'épinglerait rien.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true; paint(); onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false; paint(); onHoverChange?(false)
    }
}

// MARK: - Vu-mètre

/// Jauge horizontale continue, en encre. Le lissage se fait en amont
/// (`Bar.tick`) : la vue ne fait que dessiner la valeur qu'on lui donne.
private final class LevelMeter: NSView {
    var level: CGFloat = 0 { didSet { if level != oldValue { needsDisplay = true } } }
    var dimmed = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Style.meterWidth, height: Style.meterHeight)
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Style.ink.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        guard level > 0.001 else { return }
        // Largeur minimale = la hauteur : en dessous, la capsule dégénère en
        // demi-cercle écrasé et le témoin « ça capte » disparaît.
        let width = max(bounds.height, bounds.width * min(1, level))
        let fill = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        Style.ink.withAlphaComponent(dimmed ? 0.25 : 0.9).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - Points téléphones

/// Un cercle par téléphone, apparition et disparition animées.
///
/// La largeur est celle de `Style.maxPhones` points, TOUJOURS, même à zéro
/// téléphone : les points se remplissent dans une zone réservée au lieu de
/// pousser les boutons. Une barre qui s'élargit à chaque arrivée est une barre
/// qu'on regarde bouger au lieu de travailler.
private final class PhoneDotsView: NSView {
    private var order: [String] = []
    private var layers: [String: CALayer] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(Style.maxPhones)
        return NSSize(width: n * Style.dotSize + (n - 1) * Style.dotSpacing,
                      height: Style.dotSize)
    }

    func set(_ dots: [PhoneDot]) {
        order = dots.map(\.id)

        CATransaction.begin()
        CATransaction.setAnimationDuration(Style.appearDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

        for dot in dots {
            let circle = layers[dot.id] ?? makeCircle(id: dot.id)
            circle.backgroundColor = color(for: dot.state).cgColor
        }
        // Les téléphones partis s'effacent avant d'être retirés. Le retrait est
        // différé plutôt que posé en bloc de complétion : un seul bloc survit
        // par transaction, et plusieurs points peuvent partir ensemble.
        for (id, circle) in layers where !order.contains(id) {
            layers.removeValue(forKey: id)
            circle.opacity = 0
            circle.transform = CATransform3DMakeScale(0.2, 0.2, 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + Style.appearDuration) {
                circle.removeFromSuperlayer()
            }
        }
        CATransaction.commit()

        needsLayout = true
    }

    private func color(for state: PhoneDotState) -> NSColor {
        switch state {
        case .connected: return Style.dotConnected
        case .reconnecting: return Style.dotReconnecting
        }
    }

    private func makeCircle(id: String) -> CALayer {
        let circle = CALayer()
        circle.bounds = CGRect(x: 0, y: 0, width: Style.dotSize, height: Style.dotSize)
        circle.cornerRadius = Style.dotSize / 2
        circle.opacity = 0
        circle.transform = CATransform3DMakeScale(0.2, 0.2, 1)
        layer?.addSublayer(circle)
        layers[id] = circle
        // Le calque doit d'abord exister à l'état caché : animer dans la foulée
        // de sa création ne produirait rien, il n'y a pas encore d'ancienne
        // valeur d'où partir.
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Style.appearDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            circle.opacity = 1
            circle.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        return circle
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Style.appearDuration)
        var x = Style.dotSize / 2
        for id in order {
            layers[id]?.position = CGPoint(x: x, y: bounds.midY)
            x += Style.dotSize + Style.dotSpacing
        }
        CATransaction.commit()
    }
}

// MARK: - QR code

/// QR dessiné module par module, en encre sur le matériau du pill.
///
/// L'image brute de `CIQRCodeGenerator` est écartée : elle a un fond blanc et
/// des modules carrés, et son agrandissement bave. On lit la matrice (rendu à
/// 1 px par module, en niveaux de gris) puis on dessine chaque module comme un
/// carré à coins arrondis, sur une grille d'entiers pour rester net.
private final class QRCodeView: NSView {
    private var modules: [[Bool]] = []
    /// Côté effectif, multiple entier du module. 0 tant qu'il n'y a pas d'URL.
    private(set) var side: CGFloat = Style.qrTargetSide

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    func setURL(_ url: URL) {
        modules = QRCodeView.matrix(for: url)
        let count = CGFloat(modules.count)
        // Un module entier, sinon les arrondis tombent entre deux pixels.
        let unit = count > 0 ? max(1, (Style.qrTargetSide / count).rounded(.down)) : 0
        side = count > 0 ? unit * count : Style.qrTargetSide
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = modules.count
        guard count > 0 else { return }
        let unit = (bounds.width / CGFloat(count)).rounded(.down)
        guard unit >= 1 else { return }
        let origin = CGPoint(x: ((bounds.width - unit * CGFloat(count)) / 2).rounded(),
                             y: ((bounds.height - unit * CGFloat(count)) / 2).rounded())
        let radius = unit * 0.35
        Style.ink.setFill()
        let path = NSBezierPath()
        for (row, line) in modules.enumerated() {
            for (col, on) in line.enumerated() where on {
                let cell = NSRect(x: origin.x + CGFloat(col) * unit,
                                  y: origin.y + CGFloat(row) * unit,
                                  width: unit, height: unit)
                path.append(NSBezierPath(roundedRect: cell, xRadius: radius, yRadius: radius))
                // Deux modules voisins arrondis se touchent en un point et
                // laissent un pincement : à 5 pt par module, un motif de
                // repérage finit en collier de perles, illisible au scan. On
                // recoud le joint avec un rectangle centré sur la frontière.
                if col + 1 < line.count, line[col + 1] {
                    path.appendRect(NSRect(x: cell.midX, y: cell.minY, width: unit, height: unit))
                }
                if row + 1 < modules.count, modules[row + 1][col] {
                    path.appendRect(NSRect(x: cell.minX, y: cell.midY, width: unit, height: unit))
                }
            }
        }
        path.fill()
    }

    /// Matrice des modules, sans la zone de silence : `true` = module sombre.
    private static func matrix(for url: URL) -> [[Bool]] {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return [] }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return [] }

        let width = Int(output.extent.width), height = Int(output.extent.height)
        guard width > 0, height > 0 else { return [] }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let image = context.createCGImage(output, from: output.extent) else { return [] }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return [] }

        // Core Graphics rend l'origine en bas ; la matrice se lit du haut.
        var grid = (0..<height).map { y in
            (0..<width).map { x in pixels[(height - 1 - y) * width + x] < 128 }
        }
        // La zone de silence est redessinée par la marge du panneau : on la
        // retire ici, sinon le QR flotte décentré dans son cadre.
        while let first = grid.first, !first.contains(true) { grid.removeFirst() }
        while let last = grid.last, !last.contains(true) { grid.removeLast() }
        guard !grid.isEmpty else { return [] }
        while grid.allSatisfy({ !($0.first ?? false) }) {
            for i in grid.indices { grid[i].removeFirst() }
            if grid[0].isEmpty { return [] }
        }
        while grid.allSatisfy({ !($0.last ?? false) }) {
            for i in grid.indices { grid[i].removeLast() }
            if grid[0].isEmpty { return [] }
        }
        return grid
    }
}

// MARK: - Barre

protocol BarDelegate: AnyObject {
    func barDidToggleMute()
    func barDidEnd()
}

/// Pill sombre translucide, calé en bas à gauche de l'écran principal, avec le
/// QR de la réunion qui se déplie au-dessus. Panneau non activant : cliquer
/// dessus ne vole jamais le focus à l'application de visio.
///
/// Sa largeur est CONSTANTE d'un bout à l'autre de la réunion : chaque élément
/// réserve sa place maximale. Rien de ce qui arrive pendant une réunion
/// (téléphone qui rejoint, micro coupé) ne doit faire bouger la barre.
final class Bar {
    private weak var delegate: BarDelegate?

    private let icon = NSImageView()
    private let meter = LevelMeter()
    private let qrToggle = QRToggle()
    private let dots = PhoneDotsView()
    private lazy var muteButton = PillButton(labels: ["Couper", "Réactiver"], prominent: false,
                                             target: self, action: #selector(toggleMute))
    private lazy var endButton = PillButton(labels: ["Terminer"], prominent: true,
                                            target: self, action: #selector(end))

    private lazy var pill: PillBackground = buildPill()
    private lazy var panel: NSPanel = buildPanel()

    private let qrView = QRCodeView()
    private lazy var qrPill: HoverPanelView = buildQRPill()
    private lazy var qrPanel: NSPanel = buildQRPanel()

    private var muted = false
    private var qrShown = false
    private var overToggle = false
    private var overQR = false
    private var hoverWork: DispatchWorkItem?

    /// Valeur reçue et valeur affichée : le lissage se fait entre les deux.
    private var targetLevel: CGFloat = 0
    private var shownLevel: CGFloat = 0
    private var meterTimer: Timer?

    private(set) var isVisible = false
    /// Le QR reste déplié après un clic sur l'icône, pour laisser les gens
    /// scanner sans que la souris ait à rester posée dessus.
    private(set) var isQRPinned = false

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

        let row = NSStackView(views: [icon, meter, qrToggle, dots, muteButton, endButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.setCustomSpacing(12, after: dots)
        row.edgeInsets = NSEdgeInsets(top: 0, left: Style.pillLeftInset,
                                      bottom: 0, right: Style.pillRightInset)
        row.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            row.topAnchor.constraint(equalTo: pill.topAnchor),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: Style.pillHeight),
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

        let caption = NSTextField(labelWithString: "Scannez pour rejoindre")
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = Style.ink.withAlphaComponent(0.6)
        caption.alignment = .center

        for sub in [qrView, caption] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            qrView.topAnchor.constraint(equalTo: view.topAnchor, constant: Style.qrPadding),
            qrView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Style.qrPadding),
            qrView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Style.qrPadding),
            qrView.heightAnchor.constraint(equalTo: qrView.widthAnchor),

            caption.topAnchor.constraint(equalTo: qrView.bottomAnchor, constant: 10),
            caption.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            caption.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
        ])
        return view
    }

    private func buildQRPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 240),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        configure(panel)
        // Conteneur transparent : c'est le pill à l'intérieur qu'on met à
        // l'échelle, pas la fenêtre — redimensionner la fenêtre relancerait la
        // mise en page et ferait baver le QR.
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
        // Toujours sombre, quel que soit le thème système.
        panel.appearance = NSAppearance(named: .vibrantDark)
    }

    private func applyMicSymbol() {
        icon.image = NSImage(systemSymbolName: muted ? "mic.slash.fill" : "mic.fill",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        icon.contentTintColor = Style.ink.withAlphaComponent(muted ? 0.4 : 0.75)
    }

    // MARK: Actions

    @objc private func toggleMute() { delegate?.barDidToggleMute() }
    @objc private func end() { delegate?.barDidEnd() }

    // MARK: API

    func show() {
        guard !isVisible else { return }
        isVisible = true
        reposition(animated: false)
        let destination = targetFrame()
        panel.alphaValue = 0
        // Glissement depuis le bas, comme Eyesaver.
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
        }, completionHandler: { [self] in panel.orderOut(nil) })
    }

    /// Niveau du mix, 0…1, reçu ~20 fois par seconde. Seule la cible bouge ici :
    /// l'affichage la rejoint dans `tick`, sinon la jauge saute à chaque paquet.
    func setLevel(_ level: Float) {
        targetLevel = CGFloat(min(1, max(0, level)))
    }

    /// Aucun recalcul de fenêtre : la zone des points est déjà à sa taille
    /// maximale, les cercles se contentent de s'y allumer.
    func setPhones(_ dots: [PhoneDot]) {
        self.dots.set(Array(dots.prefix(Style.maxPhones)))
    }

    func setMuted(_ muted: Bool) {
        guard muted != self.muted else { return }
        self.muted = muted
        muteButton.update(label: muted ? "Réactiver" : "Couper")
        muteButton.tinted = muted
        applyMicSymbol()
        meter.dimmed = muted
    }

    func setJoinURL(_ url: URL) {
        qrView.setURL(url)
        qrPill.layoutSubtreeIfNeeded()
        positionQR()
    }

    // MARK: Vu-mètre

    private func startMeter() {
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        // `.common` : sinon la jauge se fige dès qu'un menu est ouvert.
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

    /// Montée rapide, descente lente : une attaque molle rate les syllabes, une
    /// descente rapide fait scintiller la jauge entre deux mots.
    private func tick() {
        let coefficient: CGFloat = targetLevel > shownLevel ? 0.45 : 0.10
        shownLevel += (targetLevel - shownLevel) * coefficient
        if abs(shownLevel - targetLevel) < 0.002 { shownLevel = targetLevel }
        meter.level = shownLevel
    }

    // MARK: Survol, épinglage et QR

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
            // Petit délai : le trajet de l'icône vers le QR passe par un vide de
            // quelques points, et sans ça le panneau clignoterait.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.overToggle, !self.overQR, !self.isQRPinned else { return }
                self.hideQR(animated: true)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Style.hoverGrace, execute: work)
        }
    }

    private func showQR() {
        guard isVisible, !qrShown else { return }
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

    /// Mise à l'échelle autour du centre, sans toucher à l'`anchorPoint` : AppKit
    /// le repositionne à chaque passe de layout, la composition manuelle survit.
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

    /// Centré au-dessus du pill, comme le pill l'est sur l'écran ; borné aux
    /// marges pour ne jamais déborder.
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

    /// Centré en bas de l'écran, comme Eyesaver. Décision Nicolas (12/09) :
    /// un coin ne marche pas avec un Dock à gauche ou en bas, le centre est
    /// neutre. `visibleFrame` : au niveau `.screenSaver` la barre passerait
    /// par-dessus le Dock si on partait du bord physique (mesuré : 44 pt de
    /// chevauchement). Dock masqué → elle descend au ras du bord.
    ///
    /// La largeur vient de `fittingSize`, mais elle est constante : tous les
    /// éléments ont une largeur figée.
    private func targetFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let width = pill.fittingSize.width.rounded()
        return NSRect(x: (screen.visibleFrame.midX - width / 2).rounded(),
                      y: (screen.visibleFrame.minY + Style.barMargin).rounded(),
                      width: width,
                      height: Style.pillHeight)
    }
}
