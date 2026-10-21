// Rasterizes a square SVG into the PNG set of a macOS .iconset directory.
// Usage: swift scripts/make-icon.swift <input.svg> <output.iconset>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <input.svg> <output.iconset>\n".utf8))
    exit(2)
}
let svgURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

guard let source = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write(Data("cannot load \(svgURL.path)\n".utf8))
    exit(1)
}

// (file name, pixel size) for every entry macOS expects in an iconset.
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (name, px) in entries {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { exit(1) }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                from: .zero, operation: .copy, fraction: 1)
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try data.write(to: outDir.appendingPathComponent(name))
}
