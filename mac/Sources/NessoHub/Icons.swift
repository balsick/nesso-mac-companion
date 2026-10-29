import AppKit
import CoreText
import Foundation

/// Renders icons on the Mac and keeps them until the Nesso asks for them.
///
/// The Nesso has no emoji font and no SF Symbols, so anything that is not plain
/// text is drawn here and sent as a bitmap. Ids are hashes of what was drawn,
/// so the Nesso's cache stays valid across reconnects and restarts.
final class IconStore {
  private var lines: [String: String] = [:]

  /// A full-colour emoji, drawn on the tile's background (RGB565).
  func emoji(_ emoji: String, size: Int, bg: String) -> String {
    // "be" marks the byte order, so icons cached by a build that sent them
    // little-endian are not reused.
    let id = Self.hash("emoji|be|\(emoji)|\(size)|\(bg)")
    if lines[id] == nil {
      let pixels = render(size: size) { ctx in
        ctx.setFillColor(color(hex: bg))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        drawCentered(emoji, font: CTFontCreateWithName("Apple Color Emoji" as CFString, CGFloat(size), nil),
                     in: ctx, size: size)
      }
      store(id: id, size: size, format: "rgb565", payload: rgb565(pixels))
    }
    return id
  }

  /// An SF Symbol as a coverage mask (A8), tinted by the tile's foreground.
  func symbol(_ name: String, size: Int) -> String {
    let id = Self.hash("symbol|\(name)|\(size)")
    if lines[id] == nil {
      let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size), weight: .bold)
      guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        log("icon", "no SF Symbol named \(name)")
        return id
      }
      let pixels = render(size: size) { ctx in
        let scale = min(CGFloat(size) / image.size.width, CGFloat(size) / image.size.height) * 0.9
        let w = image.size.width * scale, h = image.size.height * scale
        let rect = CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
      }
      store(id: id, size: size, format: "a8", payload: Data(stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }))
    }
    return id
  }

  /// The `icon` message for an id handed out earlier.
  func line(for id: String) -> String? { lines[id] }

  // MARK: Drawing

  private func store(id: String, size: Int, format: String, payload: Data) {
    lines[id] = Wire.encode([
      "t": AnyEncodable("icon"), "id": AnyEncodable(id), "w": AnyEncodable(size), "h": AnyEncodable(size),
      "f": AnyEncodable(format), "d": AnyEncodable(payload.base64EncodedString()),
    ])
  }

  /// Draws into an RGBA8 bitmap. Row 0 of the result is the top of the image.
  private func render(size: Int, draw: (CGContext) -> Void) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    pixels.withUnsafeMutableBytes { buffer in
      guard let ctx = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
      draw(ctx)
    }
    return pixels
  }

  /// Centres the glyph's ink, not its typographic box: emoji sit well above
  /// the baseline, and a few pixels matter on a 32px tile.
  private func drawCentered(_ text: String, font: CTFont, in ctx: CGContext, size: Int) {
    func line(_ font: CTFont) -> CTLine {
      CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    }
    var ctLine = line(font)
    // Image bounds are relative to the current text position.
    ctx.textPosition = .zero
    var ink = CTLineGetImageBounds(ctLine, ctx)
    if ink.width > 0, ink.height > 0 {
      let scale = min(CGFloat(size) / ink.width, CGFloat(size) / ink.height) * 0.92
      ctLine = line(CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil))
      ink = CTLineGetImageBounds(ctLine, ctx)
    }
    ctx.textPosition = CGPoint(x: (CGFloat(size) - ink.width) / 2 - ink.minX,
                               y: (CGFloat(size) - ink.height) / 2 - ink.minY)
    CTLineDraw(ctLine, ctx)
  }

  /// Big-endian RGB565: the panel's own byte order, which LovyanGFX's sprite
  /// copies as is.
  private func rgb565(_ rgba: [UInt8]) -> Data {
    var out = Data(capacity: rgba.count / 2)
    for i in stride(from: 0, to: rgba.count, by: 4) {
      let v = (UInt16(rgba[i] >> 3) << 11) | (UInt16(rgba[i + 1] >> 2) << 5) | UInt16(rgba[i + 2] >> 3)
      out.append(UInt8(v >> 8))
      out.append(UInt8(v & 0xFF))
    }
    return out
  }

  /// FNV-1a, 32 bits: short enough for a 20-byte notification, stable across runs.
  static func hash(_ key: String) -> String {
    var h: UInt32 = 0x811C_9DC5
    for byte in key.utf8 {
      h ^= UInt32(byte)
      h = h &* 0x0100_0193
    }
    return String(format: "%08x", h)
  }
}

func color(hex: String) -> CGColor {
  let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
  return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                 blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

struct AnyEncodable: Encodable {
  private let encodeValue: (Encoder) throws -> Void
  init<T: Encodable>(_ value: T) { encodeValue = value.encode }
  func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}
