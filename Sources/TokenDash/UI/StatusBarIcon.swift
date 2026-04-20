import AppKit

// MARK: - StatusBarIcon
//
// A state-aware template image for the menu bar. We don't use an SF Symbol
// because we want a thin arc + dot mark that matches the app icon and varies
// a tiny amount based on aggregate state:
//
//   .ok         — charcoal/white (template tint) arc + dot
//   .warn       — same mark but with a subtle amber badge dot in the corner
//   .danger     — red pulse badge + red dot
//
// The icon is drawn as a template image so it automatically adapts to the
// menu bar's light/dark context.

enum StatusBarState {
    case ok
    case warn
    case danger
    case offline

    static func aggregate(from snapshots: [ProviderSnapshot]) -> StatusBarState {
        var worst: StatusBarState = .ok
        for s in snapshots {
            // Danger: any hot quota (>=95%) or explicit error.
            if s.state == .error { worst = max(worst, .warn) }
            if let pctStr = s.extras["pct"], let p = Int(pctStr) {
                if p >= 95 { worst = max(worst, .danger) }
                else if p >= 80 { worst = max(worst, .warn) }
            }
        }
        return worst
    }
}

private func max(_ a: StatusBarState, _ b: StatusBarState) -> StatusBarState {
    let order: [StatusBarState: Int] = [.ok: 0, .offline: 1, .warn: 2, .danger: 3]
    return (order[a, default: 0] >= order[b, default: 0]) ? a : b
}

enum StatusBarIcon {
    static let templateSize = NSSize(width: 18, height: 18)

    /// Template image — macOS renders it white on dark menu bar, black on light.
    static func templateImage(state: StatusBarState) -> NSImage {
        let size = templateSize
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            // Arc: open dome from 200° → 340° (top of the dial).
            let cx = rect.midX, cy = rect.midY - 1
            let radius: CGFloat = 6.2

            ctx.setStrokeColor(NSColor.black.cgColor)   // template ⇒ tint ignored, stays template
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            let start: CGFloat = 200 * .pi / 180
            let end:   CGFloat =  -20 * .pi / 180   // 340° == -20°
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                       startAngle: start, endAngle: end, clockwise: false)
            ctx.strokePath()

            // Indicator dot — sits on the right tip of the arc at 340°.
            let tx = cx + radius * cos(end)
            let ty = cy + radius * sin(end)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: tx - 1.5, y: ty - 1.5, width: 3, height: 3))
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Non-template badge drawn on top of the template, so the colour survives
    /// the menu bar's auto-tint. Returns a full-size NSImage.
    static func badgedImage(state: StatusBarState) -> NSImage {
        let base = templateImage(state: state)
        guard state == .warn || state == .danger else { return base }
        let badgeColor: NSColor = (state == .danger)
            ? NSColor(srgbRed: 0.82, green: 0.30, blue: 0.24, alpha: 1.0)   // warm red
            : NSColor(srgbRed: 0.88, green: 0.60, blue: 0.20, alpha: 1.0)   // amber
        let size = base.size
        let composed = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.setFillColor(badgeColor.cgColor)
            let r: CGFloat = 3
            ctx.fillEllipse(in: CGRect(x: size.width - r * 2 - 0.5,
                                       y: size.height - r * 2 - 0.5,
                                       width: r * 2, height: r * 2))
            return true
        }
        // Leaving isTemplate = false so the colour shows through.
        composed.isTemplate = false
        return composed
    }
}
