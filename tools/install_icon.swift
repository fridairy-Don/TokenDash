#!/usr/bin/env swift
// Takes a source PNG, auto-detects the squircle body, re-masks it with a clean
// Big Sur squircle (transparent outside), and emits a full iconset.
//
// Usage: swift tools/install_icon.swift <source.png>

import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: install_icon.swift <source.png>\n".data(using: .utf8)!)
    exit(2)
}
let srcPath = CommandLine.arguments[1]
guard let srcImg = NSImage(contentsOfFile: srcPath),
      let srcCG = srcImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot load \(srcPath)\n".data(using: .utf8)!)
    exit(1)
}

// Read source pixels into an RGBA8 buffer so we can find the art bounds.
let W = srcCG.width, H = srcCG.height
let cs = CGColorSpaceCreateDeviceRGB()
var pixels = [UInt8](repeating: 0, count: W * H * 4)
let bmp = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
guard let readCtx = CGContext(
    data: &pixels, width: W, height: H,
    bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: bmp.rawValue
) else { exit(1) }
readCtx.draw(srcCG, in: CGRect(x: 0, y: 0, width: W, height: H))

// Detect bounding box of "non-background" pixels.
// Background is the dominant corner colour (white with slight cream). We treat
// any pixel whose RGB differs from corner avg by > 10 as "art".
let cornerIdxs = [0, (W-1)*4, (H-1)*W*4, ((H-1)*W + (W-1))*4]
var cr = 0, cg = 0, cb = 0
for i in cornerIdxs {
    cr += Int(pixels[i]); cg += Int(pixels[i+1]); cb += Int(pixels[i+2])
}
cr /= 4; cg /= 4; cb /= 4

var minX = W, minY = H, maxX = -1, maxY = -1
let threshold = 14
for y in 0..<H {
    let row = y * W * 4
    for x in 0..<W {
        let i = row + x * 4
        let dr = abs(Int(pixels[i])   - cr)
        let dg = abs(Int(pixels[i+1]) - cg)
        let db = abs(Int(pixels[i+2]) - cb)
        if dr + dg + db > threshold {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}
guard maxX > 0 else { FileHandle.standardError.write("no art detected\n".data(using: .utf8)!); exit(1) }

// Expand a touch so we don't shave anti-aliased edges.
let pad = 4
minX = max(0, minX - pad); minY = max(0, minY - pad)
maxX = min(W - 1, maxX + pad); maxY = min(H - 1, maxY + pad)

// Square up around art centre.
let artW = maxX - minX + 1
let artH = maxY - minY + 1
let side = max(artW, artH)
let cx = (minX + maxX) / 2
let cy = (minY + maxY) / 2
var sx = cx - side / 2
var sy = cy - side / 2
sx = max(0, min(W - side, sx))
sy = max(0, min(H - side, sy))

let cropRect = CGRect(x: sx, y: H - sy - side, width: side, height: side)   // CG uses bottom-up
print("detected art: \(artW)×\(artH) @ (\(minX),\(minY)) → crop side=\(side)")

guard let cropped = srcCG.cropping(to: cropRect) else { exit(1) }

// Render each iconset tile: canvas = side length, art fills HIG safe area
// (824/1024 ≈ 0.805). We draw the cropped squircle body clipped by a fresh
// squircle so the outside is clean transparent.
func renderTile(size: Int, source: CGImage) -> Data? {
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let s = CGFloat(size)
    let safe = s * 0.902           // art occupies ~90% — the source already has
                                   // its own interior padding around the mark.
    let inset = (s - safe) / 2
    let rect = CGRect(x: inset, y: inset, width: safe, height: safe)

    // Clip to squircle so the off-white body has clean rounded edges, nothing
    // outside leaks onto the canvas.
    let corner = safe * 0.2237     // Big Sur corner radius ratio
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(source, in: rect)
    ctx.restoreGState()

    guard let img = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: img)
    return rep.representation(using: .png, properties: [:])
}

let targets: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let fm = FileManager.default
let projectRoot = URL(fileURLWithPath: CommandLine.arguments.first.map {
    ($0 as NSString).deletingLastPathComponent + "/.."
} ?? ".")
let iconsetDir = projectRoot.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)
try? fm.removeItem(at: iconsetDir)
try? fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for t in targets {
    guard let data = renderTile(size: t.1, source: cropped) else { continue }
    let url = iconsetDir.appendingPathComponent("\(t.0).png")
    try! data.write(to: url)
    print("  \(t.0).png — \(data.count) bytes")
}
print("==> wrote \(iconsetDir.path)")
