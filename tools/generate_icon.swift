#!/usr/bin/env swift

// Generate AppIcon.iconset/ PNGs and produce AppIcon.icns.
//
// Design: Big Sur squircle with a deep warm-charcoal radial gradient, three
// concentric activity-style rings (coral / sand-gold / sage) at different fill
// levels — a direct visual metaphor for multi-provider token monitoring.
// A small cream "live" dot sits at the tip of the outer ring.
//
// Proportions chosen to stay legible at 32px+; below that a simplified
// single-ring variant is drawn so the shape still reads at Finder icon size.

import AppKit
import CoreGraphics
import Foundation

func nsColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

// MARK: - Palette

private let PALETTE_CORAL  = nsColor(0xCC785C)
private let PALETTE_GOLD   = nsColor(0xD4A56E)
private let PALETTE_SAGE   = nsColor(0x8FA87C)
private let PALETTE_CREAM  = nsColor(0xFDF7E8)
private let PALETTE_BG_HI  = nsColor(0x2B241E)   // warm charcoal (center of gradient)
private let PALETTE_BG_LO  = nsColor(0x120E0A)   // near-black (edge of gradient)

// MARK: - Drawing

private struct Ring {
    let radius: CGFloat
    let progress: CGFloat      // 0..1
    let color: NSColor
}

private func drawSquircleBackground(ctx: CGContext, rect: CGRect, colorSpace: CGColorSpace) {
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: rect.width * 0.225,
        cornerHeight: rect.width * 0.225,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    if let grad = CGGradient(
        colorsSpace: colorSpace,
        colors: [PALETTE_BG_HI.cgColor, PALETTE_BG_LO.cgColor] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawRadialGradient(
            grad,
            startCenter: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.08),
            startRadius: 0,
            endCenter: CGPoint(x: rect.midX, y: rect.midY),
            endRadius: rect.width * 0.72,
            options: []
        )
    }

    // Very subtle inner top-highlight to give the glass a tiny lift.
    if let topGlow = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            nsColor(0xE8B89A, alpha: 0.10).cgColor,
            nsColor(0xE8B89A, alpha: 0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            topGlow,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.1),
            options: []
        )
    }
    ctx.restoreGState()
}

private func strokeArc(
    ctx: CGContext,
    center: CGPoint,
    radius: CGFloat,
    startAngle: CGFloat,
    endAngle: CGFloat,
    clockwise: Bool,
    color: CGColor,
    width: CGFloat
) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    let path = CGMutablePath()
    path.addArc(
        center: center,
        radius: radius,
        startAngle: startAngle,
        endAngle: endAngle,
        clockwise: clockwise
    )
    ctx.addPath(path)
    ctx.strokePath()
}

private func drawRings(ctx: CGContext, rect: CGRect, side: CGFloat) {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let maxR = rect.width * 0.355
    let strokeW = rect.width * 0.085
    let gap = rect.width * 0.035

    let rings: [Ring] = [
        Ring(radius: maxR,                                  progress: 0.78, color: PALETTE_CORAL),
        Ring(radius: maxR - strokeW - gap,                  progress: 0.54, color: PALETTE_GOLD),
        Ring(radius: maxR - 2 * (strokeW + gap),            progress: 0.38, color: PALETTE_SAGE),
    ]

    for ring in rings where ring.radius > strokeW * 0.5 {
        // Track (subtle ghost ring).
        strokeArc(
            ctx: ctx, center: center, radius: ring.radius,
            startAngle: 0, endAngle: 2 * .pi, clockwise: false,
            color: NSColor.white.withAlphaComponent(0.055).cgColor,
            width: strokeW
        )

        // Progress arc: starts at 12 o'clock, sweeps clockwise.
        // macOS Y-up bitmap: 12 o'clock = +π/2. Clockwise sweep = decreasing angle.
        let start: CGFloat = .pi / 2
        let end = start - 2 * .pi * ring.progress
        strokeArc(
            ctx: ctx, center: center, radius: ring.radius,
            startAngle: start, endAngle: end, clockwise: true,
            color: ring.color.cgColor,
            width: strokeW
        )
    }

    // Live indicator dot at the tip of the outer ring.
    if side >= 64, let outer = rings.first {
        let tipAngle = .pi / 2 - 2 * .pi * outer.progress
        let tip = CGPoint(
            x: center.x + outer.radius * cos(tipAngle),
            y: center.y + outer.radius * sin(tipAngle)
        )
        // Soft halo.
        ctx.setFillColor(PALETTE_CREAM.withAlphaComponent(0.22).cgColor)
        ctx.addArc(center: tip, radius: side * 0.045, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.fillPath()
        // Bright dot.
        ctx.setFillColor(PALETTE_CREAM.cgColor)
        ctx.addArc(center: tip, radius: side * 0.022, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.fillPath()
    }
}

/// Simplified variant for tiny sizes (16 / 32): one clean ring + centered dot.
/// At Finder-icon-list sizes, three rings blur into mush — a single ring reads.
private func drawSimplified(ctx: CGContext, rect: CGRect, side: CGFloat) {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = rect.width * 0.3
    let strokeW = max(rect.width * 0.13, 2)

    strokeArc(
        ctx: ctx, center: center, radius: radius,
        startAngle: 0, endAngle: 2 * .pi, clockwise: false,
        color: NSColor.white.withAlphaComponent(0.10).cgColor,
        width: strokeW
    )
    let start: CGFloat = .pi / 2
    let end = start - 2 * .pi * 0.72
    strokeArc(
        ctx: ctx, center: center, radius: radius,
        startAngle: start, endAngle: end, clockwise: true,
        color: PALETTE_CORAL.cgColor,
        width: strokeW
    )
    // Small center dot.
    if side >= 24 {
        ctx.setFillColor(PALETTE_CREAM.cgColor)
        ctx.addArc(center: center, radius: side * 0.06, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.fillPath()
    }
}

func generatePNG(side: Int) -> Data? {
    let s = CGFloat(side)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS Big Sur icon geometry: content occupies ~83% of canvas.
    let inset = s * 0.085
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)

    drawSquircleBackground(ctx: ctx, rect: rect, colorSpace: colorSpace)

    if side >= 48 {
        drawRings(ctx: ctx, rect: rect, side: s)
    } else {
        drawSimplified(ctx: ctx, rect: rect, side: s)
    }

    // Hairline edge for polish on larger sizes.
    if side >= 64 {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: rect.width * 0.225,
            cornerHeight: rect.width * 0.225,
            transform: nil
        )
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.035).cgColor)
        ctx.setLineWidth(max(1, s * 0.003))
        ctx.strokePath()
    }

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Output

let targets: [(name: String, size: Int)] = [
    ("icon_16x16",    16),
    ("icon_16x16@2x", 32),
    ("icon_32x32",    32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

let projectRoot = URL(fileURLWithPath: CommandLine.arguments.first.map {
    ($0 as NSString).deletingLastPathComponent + "/.."
} ?? ".")

let iconsetDir = projectRoot.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconsetDir)
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for t in targets {
    guard let data = generatePNG(side: t.size) else {
        FileHandle.standardError.write("failed to generate \(t.name)\n".data(using: .utf8)!)
        continue
    }
    let url = iconsetDir.appendingPathComponent("\(t.name).png")
    try! data.write(to: url)
    print("   \(t.name).png (\(t.size)×\(t.size)) — \(data.count) bytes")
}

print("==> wrote \(iconsetDir.path)")
