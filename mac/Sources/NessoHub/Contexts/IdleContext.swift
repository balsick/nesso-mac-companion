import AppKit
import Foundation

/// The fallback: a clock, and the app in front.
final class IdleContext: HubContext {
  let name = "idle"
  let priority = 0
  let isActive = true
  var onChange: (() -> Void)?

  private var now = Date()
  private var frontApp = ""

  func refresh() {
    now = Date()
    frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
  }

  func page(icons: IconStore, screen: Screen) -> Page {
    let time = now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    let day = now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    // On its side 97px are left under the header: still room for the big font.
    return Page(title: "Mac", sub: frontApp, rows: [
      Row(h: screen.isWide ? 60 : 96, tiles: [Tile(label: time, bg: Palette.tile, font: "xl")]),
      Row(h: screen.isWide ? 30 : 40, tiles: [Tile(label: day, bg: Palette.tile, fg: Palette.muted, font: "m")]),
    ])
  }

  func handleTap(_ id: String) {}
}
