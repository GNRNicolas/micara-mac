import AppKit
import CoreImage
import QuartzCore

import MicaraCore

// MARK: - Pill background

/// Translucent material actually clipped to rounded corners.
///
/// `layer.cornerRadius` is not enough: in `.behindWindow` blending the blur is
/// composited by the window server across the view's whole rectangle and
/// ignores the layer mask — hence the visible box around the pill. `maskImage`
/// is the only clip compositing respects, and the window shadow follows it.
class PillBackground: NSVisualEffectView {
    /// Which corners are rounded.
    enum Corners {
        /// The floating pill.
        case all
        /// The collapsed tab. It sits flush against the screen edge, so its
        /// left corners must be square: rounding them would leave two slivers
        /// of desktop between the tab and the bezel.
        case rightOnly
    }

    var corners: Corners = .all {
        didSet {
            guard corners != oldValue else { return }
            applyMask()
            needsLayout = true
        }
    }

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
        applyMask()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // The `rightOnly` mask is cut to an exact size, so it has to be redrawn
        // whenever the view resizes — which is every frame of the collapse
        // animation. The `all` mask is stretchable and costs nothing.
        if corners == .rightOnly { applyMask() }
        // The hairline must be its own `CAShapeLayer`: `layer.borderWidth`
        // would stay rectangular, the mask does not apply to it.
        outline.frame = bounds
        outline.path = outlinePath()
    }

    private func outlinePath() -> CGPath {
        let radius = Style.pillRadius
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        switch corners {
        case .all:
            return CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .rightOnly:
            // Same trick as the mask: the rectangle is extended past the left
            // edge so its left rounding falls outside the view.
            let stretched = NSRect(x: box.minX - radius, y: box.minY,
                                   width: box.width + radius, height: box.height)
            return CGPath(roundedRect: stretched, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }

    private func applyMask() {
        switch corners {
        case .all:
            maskImage = PillBackground.mask(radius: Style.pillRadius)
        case .rightOnly:
            maskImage = PillBackground.tabMask(radius: Style.pillRadius, size: bounds.size)
        }
    }

    /// Exact-size mask for the collapsed tab: a rounded rectangle whose left
    /// half is pushed out of the image, leaving square left corners.
    private static func tabMask(radius: CGFloat, size: NSSize) -> NSImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let stretched = NSRect(x: rect.minX - radius, y: rect.minY,
                                   width: rect.width + radius, height: rect.height)
            NSBezierPath(roundedRect: stretched, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }

    /// Stretchable image: the four corners are preserved, the centre stretches.
    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // Black here is an opacity, not a colour: this is a mask.
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A background view that reports when the mouse enters and leaves. Used by
/// the QR panel: without it, moving from the icon to the panel would fold it.
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

// MARK: - Pill button

/// Pill capsule. Two styles, Eyesaver's: prominent (`ink` fill, `night` text)
/// and secondary (translucent ink). No other colour.
final class PillButton: NSButton {
    /// Every label this button may ever carry. Its width is the width of the
    /// longest one: a button that changes text must not change size, otherwise
    /// the whole pill breathes on every mute and the eye follows the movement.
    private let candidates: [String]
    private var label: String
    private let prominent: Bool
    private var hovered = false
    /// Marks the secondary button when the mic is muted. In ink, not in colour:
    /// the bar has no hue of its own.
    var tinted = false { didSet { attributedTitle = makeTitle(); paint() } }

    /// Icon-only variant: no title, a fixed square-ish footprint, and the same
    /// hover fill as the secondary style.
    private let symbol: String?
    private var iconBox = NSSize(width: Style.chevronWidth, height: 30)

    init(labels: [String], prominent: Bool, target: AnyObject, action: Selector) {
        self.candidates = labels
        self.label = labels[0]
        self.prominent = prominent
        self.symbol = nil
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.masksToBounds = true
        attributedTitle = makeTitle()
        paint()
    }

    init(symbol: String, accessibility: String,
         pointSize: CGFloat = 12, box: NSSize = NSSize(width: Style.chevronWidth, height: 30),
         target: AnyObject, action: Selector) {
        self.candidates = []
        self.label = ""
        self.prominent = false
        self.symbol = symbol
        self.iconBox = box
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.masksToBounds = true
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        attributedTitle = NSAttributedString(string: "")
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }

    // The app is never active. Without this the first click on a chevron would
    // be spent waking the app up and would collapse nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

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

    /// Width frozen once and for all, on the longest possible label (or on the
    /// icon's fixed box).
    override var intrinsicContentSize: NSSize {
        if symbol != nil { return iconBox }
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
        if symbol != nil {
            // Same ink tint as the QR icon, so the pill's two icon controls
            // read as the same family.
            contentTintColor = Style.ink.withAlphaComponent(hovered ? 0.85 : 0.55)
            layer?.backgroundColor = Style.ink.withAlphaComponent(hovered ? 0.16 : 0).cgColor
            return
        }
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

// MARK: - QR icon

/// The icon that unfolds the QR: hover for a glance, click to pin it while
/// people join.
private final class QRToggle: NSImageView {
    var onHoverChange: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private var hovered = false
    var pinned = false { didSet { paint() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "qrcode", accessibilityDescription: "Meeting QR code")?
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

    // The app is never active: without this, the first click would be spent
    // "waking it up" and would pin nothing.
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

// MARK: - Level meter

/// Continuous horizontal gauge, in ink. Smoothing happens upstream
/// (`Bar.tick`): the view only draws the value it is handed.
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
        // Minimum width = the height: below that the capsule degenerates into
        // a squashed half-circle and the "it's picking up" cue disappears.
        let width = max(bounds.height, bounds.width * min(1, level))
        let fill = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        Style.ink.withAlphaComponent(dimmed ? 0.25 : 0.9).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - Phone dots

/// One circle per phone, with animated appearance and disappearance.
///
/// The width is that of `Style.maxPhones` dots, ALWAYS, even with zero phones:
/// the dots fill a reserved area instead of pushing the buttons along. A bar
/// that widens on every arrival is a bar you watch move instead of working.
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
        // Departed phones fade out before being removed. The removal is
        // deferred rather than put in a completion block: only one block
        // survives per transaction, and several dots can leave together.
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
        // The layer must first exist in its hidden state: animating right
        // after creating it would produce nothing, there is no previous value
        // to start from yet.
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

/// QR drawn module by module, in ink on the pill's material.
///
/// The raw `CIQRCodeGenerator` image is discarded: it has a white background
/// and square modules, and it smears when enlarged. We read the matrix instead
/// (rendered at 1 px per module, in greyscale) and draw each module as a
/// rounded square, on an integer grid so it stays crisp.
private final class QRCodeView: NSView {
    private var modules: [[Bool]] = []
    /// Effective side, a whole multiple of the module. 0 until there is a URL.
    private(set) var side: CGFloat = Style.qrTargetSide

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    func setURL(_ url: URL) {
        modules = QRCodeView.matrix(for: url)
        let count = CGFloat(modules.count)
        // A whole module, otherwise the rounded corners land between pixels.
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
        let path = QRCodeView.modulePath(modules, unit: unit)
        let move = NSAffineTransform()
        move.translateX(by: origin.x, yBy: origin.y)
        path.transform(using: move as AffineTransform)
        Style.ink.setFill()
        path.fill()
    }

    /// The rounded-module path, built with row 0 at y = 0 growing DOWNWARD.
    /// The on-screen view is flipped so it draws as-is; the exported card flips
    /// it with a transform. Shared on purpose: the card must be the same
    /// drawing as the panel, not a lookalike.
    static func modulePath(_ modules: [[Bool]], unit: CGFloat) -> NSBezierPath {
        let radius = unit * 0.35
        let path = NSBezierPath()
        for (row, line) in modules.enumerated() {
            for (col, on) in line.enumerated() where on {
                let cell = NSRect(x: CGFloat(col) * unit, y: CGFloat(row) * unit,
                                  width: unit, height: unit)
                path.append(NSBezierPath(roundedRect: cell, xRadius: radius, yRadius: radius))
                // Two neighbouring rounded modules meet at a single point and
                // leave a pinch: at 5 pt per module a finder pattern ends up a
                // string of beads, unreadable to a scanner. We stitch the joint
                // back with a rectangle centred on the boundary.
                if col + 1 < line.count, line[col + 1] {
                    path.appendRect(NSRect(x: cell.midX, y: cell.minY, width: unit, height: unit))
                }
                if row + 1 < modules.count, modules[row + 1][col] {
                    path.appendRect(NSRect(x: cell.minX, y: cell.midY, width: unit, height: unit))
                }
            }
        }
        return path
    }

    /// Matrix of modules, quiet zone removed: `true` = dark module.
    static func matrix(for url: URL) -> [[Bool]] {
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

        // Core Graphics puts the origin at the bottom; the matrix reads from the top.
        var grid = (0..<height).map { y in
            (0..<width).map { x in pixels[(height - 1 - y) * width + x] < 128 }
        }
        // The quiet zone is redrawn by the panel's padding: we strip it here,
        // otherwise the QR floats off-centre in its frame.
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
    private var joinURL: URL?
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

    // MARK: - Printable card

    /// Renders the join QR onto the bundled card template and writes it to
    /// `~/Downloads`. Returns the file written, or nil if anything was missing.
    ///
    /// Everything happens in the template's PIXEL space. `NSImage.size` reports
    /// points, and the template is 144 dpi, so it would claim 900x900 for an
    /// 1800x1800 file; rendering against that silently halves the resolution.
    /// The dimensions are therefore read off an `NSBitmapImageRep` — the same
    /// trap as Eyesaver's share card, documented in its SPECS.
    @discardableResult
    func exportCard() -> URL? {
        guard let joinURL else {
            AppLog.write("card: no join URL yet")
            return nil
        }
        guard let templateURL = Bundle.main.url(forResource: "qr-card", withExtension: "png"),
              let data = try? Data(contentsOf: templateURL),
              let template = NSBitmapImageRep(data: data) else {
            AppLog.write("card: template qr-card.png missing from the bundle")
            return nil
        }
        let width = template.pixelsWide, height = template.pixelsHigh
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else {
            AppLog.write("card: could not allocate a \(width)x\(height) bitmap")
            return nil
        }
        // One point = one pixel in this context. Without it AppKit would apply
        // the template's 144 dpi again and draw at half size.
        canvas.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let full = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        template.draw(in: full)
        drawCardQR(joinURL, in: full)
        context.flushGraphics()

        // Hand the point size back before encoding. Drawing needed 1 pt = 1 px,
        // but `size` is also what the PNG stores as its resolution: left at the
        // pixel count the card would claim 72 dpi and print twice the
        // template's physical size. This only rewrites metadata, not pixels.
        canvas.size = template.size

        guard let png = canvas.representation(using: .png, properties: [:]) else {
            AppLog.write("card: PNG encoding failed")
            return nil
        }
        let code = joinURL.lastPathComponent
        guard let destination = Bar.freeDownloadsURL(named: "Micara QR \(code)") else {
            AppLog.write("card: no free filename in ~/Downloads")
            return nil
        }
        do {
            try png.write(to: destination)
        } catch {
            AppLog.write("card: write failed — \(error.localizedDescription)")
            return nil
        }
        AppLog.write("card: wrote \(destination.lastPathComponent) (\(width)x\(height))")
        return destination
    }

    /// The QR block, centred, `Style.cardQRSide` pixels a side, quiet zone
    /// included INSIDE that square. No fill behind it: the card's own off-white
    /// is the quiet zone, which is why the modules are brand ink and not white.
    private func drawCardQR(_ url: URL, in full: NSRect) {
        let modules = QRCodeView.matrix(for: url)
        let count = modules.count
        guard count > 0 else { return }

        let side = Style.cardQRSide
        // Whole pixels per module, quiet zone counted in: a fractional module
        // would blur every edge once the card is printed or zoomed.
        let slots = CGFloat(count + 2 * Style.cardQuietModules)
        let unit = max(1, (side / slots).rounded(.down))
        let extent = unit * CGFloat(count)

        let originX = (full.midX - extent / 2).rounded()
        let originY = (full.midY - extent / 2).rounded()

        let path = QRCodeView.modulePath(modules, unit: unit)
        // The path is built with row 0 at the top growing down; this bitmap
        // context has y growing up, so it is flipped about the block.
        let flip = NSAffineTransform()
        flip.translateX(by: originX, yBy: originY + extent)
        flip.scaleX(by: 1, yBy: -1)
        path.transform(using: flip as AffineTransform)

        Style.brandInk.setFill()
        path.fill()
    }

    /// `~/Downloads/<name>.png`, or `<name>-2.png`, `<name>-3.png`… Never
    /// overwrites: two meetings in a day must not clobber each other's card.
    private static func freeDownloadsURL(named name: String) -> URL? {
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
        for suffix in 1...99 {
            let filename = suffix == 1 ? "\(name).png" : "\(name)-\(suffix).png"
            let candidate = downloads.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: API

    func show() {
        guard !isVisible else { return }
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
        }, completionHandler: { [self] in panel.orderOut(nil) })
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
        guard isVisible, !isCollapsed, !qrShown else { return }
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
