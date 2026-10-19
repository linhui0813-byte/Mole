import AppKit

// Reuse the exact mascot pixels from the upstream banner; all derived files
// stay in the ignored desktop build directory. Coordinates use image top-left.
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let data = try Data(contentsOf: sourceURL)
guard let source = NSBitmapImageRep(data: data)?.cgImage,
      source.width == 1280, source.height == 640,
      let circle = source.cropping(to: CGRect(x: 66, y: 112, width: 440, height: 440)),
      let mascot = source.cropping(to: CGRect(x: 104, y: 222, width: 354, height: 210)) else {
    fatalError("The upstream banner layout changed. Review the Mole logo crops before building.")
}
let iconset = output.appendingPathComponent("MoleDashboard.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4,
                     bitsPerPixel: 32)!
}

func write(_ image: NSBitmapImageRep, to url: URL) throws {
    try image.representation(using: .png, properties: [:])!.write(to: url)
}

func logo(size: Int, inset: CGFloat = 0) -> NSBitmapImageRep {
    let image = bitmap(width: size, height: size)
    let context = NSGraphicsContext(bitmapImageRep: image)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let bounds = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
    context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.cgContext.addEllipse(in: bounds)
    context.cgContext.clip()
    context.cgContext.interpolationQuality = .high
    context.cgContext.draw(circle, in: bounds)
    NSGraphicsContext.restoreGraphicsState()
    return image
}

try write(logo(size: 440), to: output.appendingPathComponent("MoleLogo.png"))
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let suffix = scale == 2 ? "@2x" : ""
        try write(logo(size: size, inset: CGFloat(size) * 0.06),
                  to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

// The cream background becomes transparent; the original dark mascot and its
// eye/claw cutouts become an alpha mask macOS can tint for either menu bar theme.
let mask = bitmap(width: mascot.width, height: mascot.height)
let context = NSGraphicsContext(bitmapImageRep: mask)!
context.cgContext.draw(mascot, in: CGRect(x: 0, y: 0, width: mascot.width, height: mascot.height))
for y in 0..<mask.pixelsHigh {
    for x in 0..<mask.pixelsWide {
        let offset = y * mask.bytesPerRow + x * 4
        let pixels = mask.bitmapData!
        let coverage = max(0, min(1, (248 - Double(pixels[offset])) / 208))
        pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0
        pixels[offset + 3] = UInt8((coverage * 255).rounded())
    }
}
try write(mask, to: output.appendingPathComponent("MoleMenuTemplate.png"))
print("Prepared upstream Mole logo, app icon set, and menu bar template.")
