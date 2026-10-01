import AppKit

/// The one drawing of the mark: a gauge arc with a needle. The app icon and the menu bar glyph
/// both come from here, so they can't drift apart.
enum Logo {
  /// Arc runs from lower-left (210°) over the top to lower-right (-30°).
  static let startAngle = 210.0 * .pi / 180
  static let endAngle = -30.0 * .pi / 180

  static func angle(_ level: Double) -> CGFloat {
    CGFloat(startAngle + (endAngle - startAngle) * min(max(level, 0), 1))
  }

  /// Monochrome template for the menu bar. `level` 0…1 sets the needle.
  static func menuBarImage(level: Double, size: CGFloat = 18) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
      let c = CGPoint(x: rect.midX, y: rect.midY - size * 0.06)
      let r = size * 0.40
      let w = size * 0.11
      ctx.setLineCap(.round)
      ctx.setStrokeColor(NSColor.black.cgColor)
      ctx.setFillColor(NSColor.black.cgColor)

      // Dimmed track, then the filled part up to the needle.
      ctx.setLineWidth(w)
      ctx.setAlpha(0.35)
      ctx.addArc(center: c, radius: r, startAngle: startAngle, endAngle: endAngle, clockwise: true)
      ctx.strokePath()
      ctx.setAlpha(1)
      ctx.addArc(center: c, radius: r, startAngle: startAngle, endAngle: angle(level), clockwise: true)
      ctx.strokePath()

      needle(ctx, center: c, length: r * 0.86, width: w * 0.95, level: level)
      ctx.fillEllipse(in: CGRect(x: c.x - w * 1.1, y: c.y - w * 1.1, width: w * 2.2, height: w * 2.2))
      return true
    }
    image.isTemplate = true
    return image
  }

  private static func needle(_ ctx: CGContext, center c: CGPoint, length: CGFloat, width: CGFloat, level: Double) {
    let a = angle(level)
    ctx.setLineWidth(width)
    ctx.move(to: c)
    ctx.addLine(to: CGPoint(x: c.x + cos(a) * length, y: c.y + sin(a) * length))
    ctx.strokePath()
  }

  /// Full-colour app icon at `px` square, on the macOS icon grid (824/1024 body, continuous corners).
  static func appIcon(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return rep }

    let s = CGFloat(px) / 1024
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s).cgPath

    // Drop shadow + dark body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.10, blue: 0.13, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(
      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 0.20, green: 0.20, blue: 0.25, alpha: 1).cgColor,
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1).cgColor,
      ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    let c = CGPoint(x: 512 * s, y: 470 * s)
    let r = 270 * s
    let w = 74 * s
    let level = 0.68

    // Track.
    ctx.setLineCap(.round)
    ctx.setLineWidth(w)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.addArc(center: c, radius: r, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ctx.strokePath()

    // Filled arc: warm gradient, clipped to the stroked arc up to the needle.
    ctx.saveGState()
    ctx.addArc(center: c, radius: r, startAngle: startAngle, endAngle: angle(level), clockwise: true)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let warm = CGGradient(
      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 1.00, green: 0.78, blue: 0.25, alpha: 1).cgColor,
        NSColor(srgbRed: 1.00, green: 0.50, blue: 0.16, alpha: 1).cgColor,
        NSColor(srgbRed: 0.96, green: 0.27, blue: 0.36, alpha: 1).cgColor,
      ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(warm, start: CGPoint(x: c.x - r, y: c.y), end: CGPoint(x: c.x + r, y: c.y), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Ticks inside the arc.
    ctx.setLineWidth(10 * s)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    for i in 0...8 {
      let a = angle(Double(i) / 8)
      let r0 = r - w / 2 - 34 * s, r1 = r - w / 2 - 66 * s
      ctx.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
      ctx.addLine(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
    }
    ctx.strokePath()

    // Needle + hub.
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    needle(ctx, center: c, length: r * 0.82, width: 30 * s, level: level)
    ctx.fillEllipse(in: CGRect(x: c.x - 46 * s, y: c.y - 46 * s, width: 92 * s, height: 92 * s))
    ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.10, blue: 0.13, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - 16 * s, y: c.y - 16 * s, width: 32 * s, height: 32 * s))
    ctx.restoreGState()
    return rep
  }

  /// `AgentMeter --iconset <dir>`: writes the PNGs `iconutil` turns into AppIcon.icns.
  static func writeIconset(to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for pt in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try appIcon(px: pt * scale).representation(using: .png, properties: [:])!.write(to: dir.appending(path: name))
      }
    }
  }
}
