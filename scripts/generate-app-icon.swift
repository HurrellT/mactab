#!/usr/bin/env swift
import AppKit

// Render the same SF Symbol used by the menu bar into a standalone Finder icon.
// Run only when updating the asset; normal builds copy the checked-in ICNS file.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let side = CGFloat(pixels)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1).setFill()
        let tile = NSRect(x: side * 0.07, y: side * 0.07, width: side * 0.86, height: side * 0.86)
        NSBezierPath(roundedRect: tile, xRadius: side * 0.19, yRadius: side * 0.19).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.5, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "MacTab")?
            .withSymbolConfiguration(configuration) else { fatalError("The menu bar symbol is unavailable") }
        let ratio = min(side * 0.57 / symbol.size.width, side * 0.57 / symbol.size.height)
        let width = symbol.size.width * ratio
        let height = symbol.size.height * ratio
        symbol.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(size)x\(size)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated \(output.path)")
