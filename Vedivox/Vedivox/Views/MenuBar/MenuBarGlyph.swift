import AppKit

/// The status bar sign: the small cut F0 of the N2 sign redrawn for 18 pt —
/// a closed V, a hole around its tip and the record lamp in the hole. The parts carry the
/// state: the left stroke is «я», the right one «они», the lamp is the recording.
/// Same drawing as the 16 and 32 px app icon of `scripts/app_icon.py`, in points of the
/// 18 × 18 box, y down.
enum MenuBarGlyph {
    enum Lamp {
        /// Not recording.
        case ring
        /// Recording.
        case solid
        /// Working: an open arc.
        case arc
    }

    private static let side: CGFloat = 18
    private static let strokeWidth: CGFloat = 2
    private static let leftEnd = CGPoint(x: 4.5, y: 4.3)
    private static let rightEnd = CGPoint(x: 13.5, y: 4.3)
    private static let tip = CGPoint(x: 9, y: 12.3)
    private static let holeRadius: CGFloat = 2.8
    private static let lampRadius: CGFloat = 2.1
    /// A switched-off stroke keeps this much of the ink.
    static let dimmed: CGFloat = 0.35

    /// `me` and `them` are the alpha of each stroke, 0 leaves it out. Without `color`
    /// the image is a template and the status bar inks it; with it the colour is baked in.
    static func image(
        me: CGFloat = 1,
        them: CGFloat = 1,
        lamp: Lamp,
        color: NSColor? = nil,
        label: String
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // A template keeps only the alpha, so its ink is any opaque colour.
            let ink = color?.cgColor ?? CGColor(gray: 0, alpha: 1)
            cg.setLineCap(.round)
            // Each half is its stroke cut along the vertical through the tip.
            let halves = [
                (me, leftEnd, CGRect(x: 0, y: 0, width: tip.x, height: side)),
                (them, rightEnd, CGRect(x: tip.x, y: 0, width: side - tip.x, height: side)),
            ]
            for (alpha, end, half) in halves where alpha > 0 {
                cg.saveGState()
                cg.clip(to: half)
                cg.setStrokeColor(ink.copy(alpha: ink.alpha * alpha) ?? ink)
                cg.setLineWidth(strokeWidth)
                cg.move(to: end)
                cg.addLine(to: tip)
                cg.strokePath()
                cg.restoreGState()
            }
            // A real hole, so the bar shows through the ring around the lamp.
            cg.setBlendMode(.clear)
            cg.fillEllipse(in: circle(holeRadius))
            cg.setBlendMode(.normal)

            cg.setFillColor(ink)
            cg.setStrokeColor(ink)
            let ringWidth = lampRadius * 0.44
            let ringRadius = lampRadius - ringWidth / 2
            cg.setLineWidth(ringWidth)
            switch lamp {
            case .solid:
                cg.fillEllipse(in: circle(lampRadius))
            case .ring:
                cg.strokeEllipse(in: circle(ringRadius))
            case .arc:
                // Three quarters, clockwise on screen from the top to the left.
                cg.addArc(center: tip, radius: ringRadius, startAngle: -.pi / 2, endAngle: .pi, clockwise: false)
                cg.strokePath()
            }
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = label
        return image
    }

    private static func circle(_ radius: CGFloat) -> CGRect {
        CGRect(x: tip.x - radius, y: tip.y - radius, width: 2 * radius, height: 2 * radius)
    }
}
