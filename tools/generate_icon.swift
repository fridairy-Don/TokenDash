#!/usr/bin/env swift

// Generate AppIcon.iconset/ PNGs and produce AppIcon.icns.
//
// Design: macOS Big Sur-style squircle, coral (#CC785C) background, cream
// serif "T" monogram (a nod to tokens, and to the app name). Subtle inner
// highlight for depth. Safe-area aware so it reads at 16×16.

import AppKit
import CoreGraphics
import Foundation

func nsColor(_ hex: UInt32) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

func generatePNG(side: Int) -> Data? {
    let s = CGFloat(side)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS Big Sur icon geometry: content occupies ~82% of canvas, rest is padding.
    let inset = s * 0.085
    let squircleRect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let cornerRadius = squircleRect.width * 0.225   // squircle-ish curvature

    // Coral fill
    let squirclePath = CGPath(
        roundedRect: squircleRect,
        cornerWidth: cornerRadius, cornerHeight: cornerRadius,
        transform: nil
    )
    ctx.addPath(squirclePath)
    ctx.setFillColor(nsColor(0xCC785C).cgColor)
    ctx.fillPath()

    // Subtle top highlight (a very light gradient for depth) — skip on 16px.
    if side >= 32 {
        ctx.saveGState()
        ctx.addPath(squirclePath)
        ctx.clip()
        if let grad = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                nsColor(0xE8A78F).withAlphaComponent(0.35).cgColor,
                nsColor(0xCC785C).withAlphaComponent(0.0).cgColor,
            ] as CFArray,
            locations: [0.0, 0.55]
        ) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: squircleRect.midX, y: squircleRect.maxY),
                end: CGPoint(x: squircleRect.midX, y: squircleRect.midY - squircleRect.height * 0.1),
                options: []
            )
        }
        ctx.restoreGState()
    }

    // Serif "T" monogram
    let cream = nsColor(0xFDFBF5)
    let fontSize = s * 0.56
    let candidates = ["New York", "Source Serif 4", "Source Serif Pro", "Times New Roman"]
    var font: NSFont? = nil
    for name in candidates {
        if let f = NSFont(name: name, size: fontSize) { font = f; break }
    }
    let desc = (font ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold))
        .fontDescriptor
        .withSymbolicTraits([.bold])
    let monoFont = NSFont(descriptor: desc, size: fontSize)
        ?? NSFont.systemFont(ofSize: fontSize, weight: .heavy)

    let attrs: [NSAttributedString.Key: Any] = [
        .font: monoFont,
        .foregroundColor: cream,
        .kern: -fontSize * 0.02,
    ]
    let str = NSAttributedString(string: "T", attributes: attrs)
    let strSize = str.size()
    let line = CTLineCreateWithAttributedString(str)

    // Center optically (serif "T" tends to look a hair too low at geometric center)
    let tx = (s - strSize.width) / 2
    let ty = (s - strSize.height) / 2 + s * 0.03

    ctx.textPosition = CGPoint(x: tx, y: ty)
    CTLineDraw(line, ctx)

    // Small cream dot to echo the coral dot in the wordmark, bottom-right.
    if side >= 64 {
        let dotR = s * 0.045
        let dotX = squircleRect.maxX - dotR * 3.2
        let dotY = squircleRect.minY + dotR * 3.2
        ctx.setFillColor(cream.withAlphaComponent(0.85).cgColor)
        ctx.addArc(center: CGPoint(x: dotX, y: dotY), radius: dotR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
    }

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

// Required iconset manifest
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
