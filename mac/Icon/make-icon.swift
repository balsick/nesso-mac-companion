// Draws the app icon: a Nesso N1 showing four tiles (mic, camera and two
// reactions) on a teal squircle, and writes it as an .icns.
//
//   swift Icon/make-icon.swift Icon/AppIcon.icns
import AppKit
import CoreText

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"

func rgb(_ hex: UInt32) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
  CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawSymbol(_ name: String, in rect: CGRect, ctx: CGContext) {
  let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .bold)
    .applying(.init(paletteColors: [.white]))
  guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
  else { return }
  let scale = min(rect.width / image.size.width, rect.height / image.size.height)
  let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
  image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                        height: size.height))
  NSGraphicsContext.restoreGraphicsState()
}

func drawEmoji(_ emoji: String, in rect: CGRect, ctx: CGContext) {
  let font = CTFontCreateWithName("Apple Color Emoji" as CFString, rect.height, nil)
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: [.font: font]))
  // Image bounds are measured from the current text position, which the
  // previous draw left wherever it ended.
  ctx.textPosition = .zero
  let ink = CTLineGetImageBounds(line, ctx)
  let scale = min(rect.width / ink.width, rect.height / ink.height)
  let fitted = CTLineCreateWithAttributedString(NSAttributedString(
    string: emoji, attributes: [.font: CTFontCreateWithName("Apple Color Emoji" as CFString, rect.height * scale, nil)]))
  let box = CTLineGetImageBounds(fitted, ctx)
  ctx.textPosition = CGPoint(x: rect.midX - box.width / 2 - box.minX, y: rect.midY - box.height / 2 - box.minY)
  CTLineDraw(fitted, ctx)
}

/// The 1024pt master, following Apple's icon grid: an 824pt squircle with
/// room for its shadow.
func drawIcon(_ ctx: CGContext) {
  let canvas = CGRect(x: 100, y: 100, width: 824, height: 824)

  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
  ctx.addPath(roundedRect(canvas, 185))
  ctx.setFillColor(rgb(0x00695C))
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(roundedRect(canvas, 185))
  ctx.clip()
  let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [rgb(0x1DE9B6), rgb(0x00897B), rgb(0x004D40)] as CFArray,
                            locations: [0, 0.55, 1])!
  ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
  ctx.restoreGState()

  // The Nesso: a light body with a dark screen, portrait.
  let body = CGRect(x: 512 - 205, y: 512 - 330, width: 410, height: 660)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: CGColor(gray: 0, alpha: 0.45))
  ctx.addPath(roundedRect(body, 70))
  ctx.setFillColor(rgb(0xECEFF1))
  ctx.fillPath()
  ctx.restoreGState()

  let screen = body.insetBy(dx: 34, dy: 34)
  ctx.addPath(roundedRect(screen, 42))
  ctx.setFillColor(rgb(0x101417))
  ctx.fillPath()

  // Four tiles in a 2x2 grid, as the Meet page lays them out.
  let gap: CGFloat = 22
  let tileW = (screen.width - 3 * gap) / 2
  let tileH = (screen.height - 3 * gap) / 2
  func tile(_ col: Int, _ row: Int) -> CGRect {
    CGRect(x: screen.minX + gap + CGFloat(col) * (tileW + gap),
           y: screen.maxY - gap - tileH - CGFloat(row) * (tileH + gap), width: tileW, height: tileH)
  }
  let tiles: [(CGRect, UInt32)] = [(tile(0, 0), 0xE53935), (tile(1, 0), 0x43A047),
                                   (tile(0, 1), 0x263238), (tile(1, 1), 0x263238)]
  for (rect, colour) in tiles {
    ctx.addPath(roundedRect(rect, 30))
    ctx.setFillColor(rgb(colour))
    ctx.fillPath()
  }
  drawSymbol("mic.slash.fill", in: tile(0, 0).insetBy(dx: 30, dy: 62), ctx: ctx)
  drawSymbol("video.fill", in: tile(1, 0).insetBy(dx: 26, dy: 70), ctx: ctx)
  drawEmoji("🎉", in: tile(0, 1).insetBy(dx: 18, dy: 52), ctx: ctx)
  drawEmoji("👍", in: tile(1, 1).insetBy(dx: 18, dy: 52), ctx: ctx)
}

func png(size: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
  let context = NSGraphicsContext(bitmapImageRep: rep)!
  let ctx = context.cgContext
  ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
  ctx.interpolationQuality = .high
  drawIcon(ctx)
  context.flushGraphics()
  return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
  try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote \(output)" : "iconutil failed")
