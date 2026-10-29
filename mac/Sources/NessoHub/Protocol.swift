import CoreBluetooth
import Foundation

/// The wire format shared with firmware/NessoHub. Both directions carry one
/// JSON object per line; see README.md for the message list.
enum Wire {
  /// Must match HUB_PROTOCOL_VERSION in firmware/NessoHub/config.h.
  static let version = 1
  static let service = CBUUID(string: "8c3b0001-5b1e-4c39-9d5e-6f1a7e2b9c40")
  /// The Mac writes here.
  static let rx = CBUUID(string: "8c3b0002-5b1e-4c39-9d5e-6f1a7e2b9c40")
  /// The Nesso notifies here.
  static let tx = CBUUID(string: "8c3b0003-5b1e-4c39-9d5e-6f1a7e2b9c40")

  static let screenWidth = 135
  static let screenHeight = 240

  static func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }
}

/// One tile on the Nesso. Tiles in a row share its width equally.
struct Tile: Encodable {
  var id: String?
  var label: String?
  var icon: String?
  var bg: String?
  var fg: String?
  /// "s", "m", "l" or "xl".
  var font: String?

  init(id: String? = nil, label: String? = nil, icon: String? = nil, bg: String? = nil,
       fg: String? = nil, font: String? = nil) {
    self.id = id
    // The firmware's fonts are ASCII-only.
    self.label = label.map(asciiLabel)
    self.icon = icon
    self.bg = bg
    self.fg = fg
    self.font = font
  }
}

struct Row: Encodable {
  var h: Int
  var tiles: [Tile]
}

struct Page: Encodable, Equatable {
  let t = "page"
  var title: String
  var sub: String?
  var accent: String?
  var rows: [Row]

  init(title: String, sub: String? = nil, accent: String? = nil, rows: [Row]) {
    self.title = asciiLabel(title)
    self.sub = sub.map(asciiLabel)
    self.accent = accent
    self.rows = rows
  }

  static func == (a: Page, b: Page) -> Bool { Wire.encode(a) == Wire.encode(b) }
}

/// Folds accents and drops anything the firmware cannot draw.
func asciiLabel(_ text: String) -> String {
  let folded = text.applyingTransform(.stripDiacritics, reverse: false) ?? text
  return String(folded.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }.map(Character.init))
}

/// A message from the Nesso.
struct Event: Decodable {
  let t: String
  let id: String?
  let k: String?
  let a: String?
  let ids: [String]?
  let fw: String?
  let proto: Int?
}
