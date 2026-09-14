import AppKit
import CoreImage
import QuartzCore

import MicaraCore

// MARK: - Hover tracking

extension NSView {
    /// The bar's three hover-sensitive views all want the same tracking area:
    /// the whole view, followed even when Micara is not the frontmost app
    /// (`.activeAlways`) and kept in step with scrolling (`.inVisibleRect`).
    /// Call it from `updateTrackingAreas()`, after `super`.
    func refreshHoverTracking() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
}

// The bar's reusable views, split out of Bar.swift: the pill's material and
// its capsule buttons, the level meter, the phone dots, the QR icon and the
// QR drawing itself. None of them knows about the meeting — they draw what
// `Bar` hands them, which is what keeps Bar.swift about windows and state.

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
final class HoverPanelView: PillBackground {
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshHoverTracking()
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
        refreshHoverTracking()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; paint() }
    override func mouseExited(with event: NSEvent) { hovered = false; paint() }
}

// MARK: - QR icon

/// The icon that unfolds the QR: hover for a glance, click to pin it while
/// people join.
final class QRToggle: NSImageView {
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
        refreshHoverTracking()
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
final class LevelMeter: NSView {
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
final class PhoneDotsView: NSView {
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
final class QRCodeView: NSView {
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
        // otherwise the QR floats off-centre in its frame. Blank columns are
        // blank rows of the transposed grid — one trim, used twice.
        guard let rows = trimBlankEdges(grid),
              let columns = trimBlankEdges(transposed(rows)) else { return [] }
        return transposed(columns)
    }

    /// Drops the all-white rows at both ends. `nil` if nothing is left.
    private static func trimBlankEdges(_ grid: [[Bool]]) -> [[Bool]]? {
        var grid = grid
        while let first = grid.first, !first.contains(true) { grid.removeFirst() }
        while let last = grid.last, !last.contains(true) { grid.removeLast() }
        return grid.isEmpty ? nil : grid
    }

    private static func transposed(_ grid: [[Bool]]) -> [[Bool]] {
        guard let width = grid.first?.count, width > 0 else { return [] }
        return (0..<width).map { x in grid.map { $0[x] } }
    }
}
