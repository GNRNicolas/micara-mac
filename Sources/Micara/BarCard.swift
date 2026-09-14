import AppKit

import MicaraCore

// The printable QR card, split out of Bar.swift: rendering the join QR onto
// the bundled template and writing it to ~/Downloads. It lives apart because
// it is the one part of the bar that draws into a bitmap rather than on
// screen, with its own pixel-space rules.

extension Bar {
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
}
