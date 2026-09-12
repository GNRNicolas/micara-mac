import AppKit

// MARK: - Style

/// Colours and geometry. None of it is persisted, none of it is exposed to the user.
///
/// Taken from Eyesaver, one colour aside. Inherited rule, still upheld: neither
/// pure white nor pure black anywhere the eye can see them — `ink` and `night`
/// are the warm versions, everything else is an alpha of those two.
enum Style {
    /// Brand tile and dots, from the logo SVG (#FFFF3F / #2D2F40). Used by the
    /// logo only; the rest of the bar stays on Eyesaver's ink and night.
    static let brandYellow = NSColor(calibratedRed: 1.0, green: 1.0, blue: 0.247, alpha: 1)
    static let brandInk = NSColor(calibratedRed: 0.176, green: 0.184, blue: 0.251, alpha: 1)

    /// Accent blue, provisional: Nicolas will supply the logo and its palette.
    /// ONE constant only, so that replacing it is a `git grep accent`.
    /// Calibrated rather than sRGB, like Eyesaver's orange: the value is picked
    /// by eye on a dark background, not converted from a hex.
    ///
    /// Reserved for the BORDER. The bar is pure `ink`/`night`, exactly like
    /// Eyesaver: the border is what says "meeting in progress", the bar has no
    /// business repeating it in colour.
    static let accent = NSColor(calibratedRed: 0.24, green: 0.53, blue: 1.0, alpha: 1.0)

    /// Off-white, #FBFBF2. Pure white is harsh on the dark material.
    static let ink = NSColor(srgbRed: 0xFB / 255, green: 0xFB / 255, blue: 0xF2 / 255, alpha: 1)
    /// Near-black, #1E1E1C. The warm counterpart of `ink`, used for text sitting
    /// on a light fill (primary button).
    static let night = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1C / 255, alpha: 1)

    // MARK: Border

    /// Half of Eyesaver's (12): here the border signals a meeting in progress,
    /// not an alert you must not miss. It has to be noticed without eating into
    /// the screen.
    static let borderWidth: CGFloat = 6
    /// Concerns the INNER edge of the ring only. The outer edge hugs the screen,
    /// whose bottom corners are square.
    static let borderInnerRadius: CGFloat = 18
    /// Fixed opacity: no pulsing, unlike Eyesaver. A meeting lasts an hour, and
    /// an hour of blinking is unbearable.
    static let borderOpacity: Float = 0.9
    static let borderFade: TimeInterval = 0.22

    // MARK: Pill

    static let pillRadius: CGFloat = 16
    static let pillHeight: CGFloat = 60
    /// ONE margin, left and bottom alike (Eyesaver's value). The corner must
    /// look square: two constants always end up drifting apart.
    ///
    /// Measured from the edge of the SCREEN, not from `visibleFrame`, on the
    /// vertical axis: a Dock at the bottom would push the bar up by its height
    /// and the corner would stop being square — and the bar would move
    /// depending on whether the Dock is hidden. Horizontally we start from the
    /// usable edge instead, because a side Dock really does occupy the place
    /// the bar would go (see `Bar.targetFrame`).
    static let barMargin: CGFloat = 15
    /// Content insets, left and right.
    static let pillLeftInset: CGFloat = 16
    static let pillRightInset: CGFloat = 14

    // MARK: Level meter

    static let meterWidth: CGFloat = 56
    /// Size shared by the pill's icons (mic, QR).
    static let iconBox: CGFloat = 22
    static let meterHeight: CGFloat = 8

    // MARK: Phone dots

    static let dotSize: CGFloat = 8
    static let dotSpacing: CGFloat = 6
    /// Slots reserved up front, even when the meeting is empty: this is the
    /// server's limit (`MICARA_MAX_PHONES`, default 8). Reserving the area is
    /// what guarantees the pill never moves by a dot's width.
    static let maxPhones = 8
    /// The pill's only two colours: they carry MEANING (it works / it struggles),
    /// not an identity. System colours, so they stay legible whatever the
    /// machine's contrast setting.
    static let dotConnected = NSColor.systemGreen
    static let dotReconnecting = NSColor.systemOrange

    // MARK: QR panel

    /// Target side of the QR. The real size is rounded to a whole multiple of
    /// the module, so the matrix lands exactly on the dot grid.
    static let qrTargetSide: CGFloat = 180
    static let qrPadding: CGFloat = 16
    /// Gap between the top of the pill and the bottom of the QR panel.
    static let qrGap: CGFloat = 10

    // MARK: Animations

    /// Durations and curve shared by every transition, taken from Eyesaver:
    /// an appearance slightly slower than a disappearance.
    static let appearDuration: TimeInterval = 0.22
    static let disappearDuration: TimeInterval = 0.16
    /// Anti-flicker delay before folding the QR back when the mouse leaves.
    static let hoverGrace: TimeInterval = 0.15
}
