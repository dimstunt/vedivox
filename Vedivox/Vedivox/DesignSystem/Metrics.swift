import CoreGraphics

/// Spacing scale from the design system (`space-2xs` … `space-3xl`).
/// Values in between (1, 3, 5, 9, 10, 14) snap to a step.
enum VedivoxSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let xxxl: CGFloat = 24
}

/// Fixed sizes from the design system.
enum VedivoxSize {
    /// Recording, confidence, status and speaker dots — one size everywhere.
    static let dot: CGFloat = 8
}

/// Corner radii from the design system. Capsules and dots use `Capsule()` /
/// `Circle()`; nested shapes take outer radius − inset.
enum VedivoxRadius {
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 18
}
