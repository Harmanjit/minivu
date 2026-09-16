// Draws minivu's icons from the vector original, Assets/AppIcon.pdf:
//
//   Assets/AppIcon.icns          every size macOS asks for, 16 to 1024 px
//   Assets/minivu-icon.png       512 px, for the README and the wiki
//   Assets/social-preview.png    1280 x 640, GitHub's link preview
//
// Run from the repository root after changing the PDF:
//   swift scripts/make_icon.swift
//
// Each size is drawn from the vectors, not scaled from a bitmap, so small
// sizes stay sharp. The artwork is fitted to Apple's macOS icon grid: its
// rounded square fills 824 of 1024 px, centred, with the soft shadow system
// icons have, so it sits the same size as its neighbours in the Dock.

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
guard let page = CGPDFDocument(assets.appendingPathComponent("AppIcon.pdf") as CFURL)?.page(at: 1) else {
    fatalError("Can't read Assets/AppIcon.pdf; run from the repository root")
}
let box = page.getBoxRect(.cropBox)

/// The share of the page the artwork covers, measured from its transparent edge.
let artworkShare = artworkFraction()

func bitmap(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func drawPage(_ context: CGContext, in rect: CGRect) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.minY)
    context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
    context.drawPDFPage(page)
    context.restoreGState()
}

func artworkFraction() -> CGFloat {
    let size = 512
    let context = bitmap(size, size)
    drawPage(context, in: CGRect(x: 0, y: 0, width: size, height: size))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var first = size, last = 0
    for y in 0..<size {
        for x in 0..<size where pixels[(y * size + x) * 4 + 3] > 8 {
            first = min(first, x); last = max(last, x)
        }
    }
    return CGFloat(last - first + 1) / CGFloat(size)
}

/// The icon on Apple's grid, in a square `tile`.
func drawIcon(_ context: CGContext, in tile: CGRect) {
    let unit = tile.width / 1024
    let side = 824 * unit / artworkShare
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 20 * unit,
                      color: CGColor(gray: 0, alpha: 0.3))
    drawPage(context, in: CGRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side))
    context.restoreGState()
}

func write(_ context: CGContext, to url: URL) {
    let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

func icon(_ size: Int) -> CGContext {
    let context = bitmap(size, size)
    context.interpolationQuality = .high
    drawIcon(context, in: CGRect(x: 0, y: 0, width: size, height: size))
    return context
}

// The .icns, through an iconset folder that iconutil packs.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    write(icon(points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    write(icon(points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
try? FileManager.default.removeItem(at: iconset)

write(icon(512), to: assets.appendingPathComponent("minivu-icon.png"))

// The link preview: the icon beside the name, on a dark ground that GitHub
// shows well in light and dark mode.
let preview = bitmap(1280, 640)
preview.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
preview.fill(CGRect(x: 0, y: 0, width: 1280, height: 640))
drawIcon(preview, in: CGRect(x: 110, y: 150, width: 340, height: 340))
NSGraphicsContext.current = NSGraphicsContext(cgContext: preview, flipped: false)
NSAttributedString(string: "minivu", attributes: [
    .font: NSFont.systemFont(ofSize: 132, weight: .semibold), .foregroundColor: NSColor.white,
]).draw(at: CGPoint(x: 500, y: 300))
let tagline = "A fast image browser, viewer and editor\nfor Apple Silicon Macs"
NSAttributedString(string: tagline, attributes: [
    .font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor(white: 0.7, alpha: 1),
]).draw(in: CGRect(x: 506, y: 170, width: 700, height: 110))
write(preview, to: assets.appendingPathComponent("social-preview.png"))

print("Wrote Assets/AppIcon.icns, Assets/minivu-icon.png and Assets/social-preview.png")
