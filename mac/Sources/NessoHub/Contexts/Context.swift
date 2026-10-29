import Foundation

/// One use of the Nesso. The hub asks every context whether it wants the
/// screen and shows the active one with the highest priority.
protocol HubContext: AnyObject {
  var name: String { get }
  var priority: Int { get }
  /// Whether this context wants the screen right now.
  var isActive: Bool { get }
  /// Set by the hub: call it when the page should be rebuilt before the next
  /// tick, typically right after acting on a tap.
  var onChange: (() -> Void)? { get set }

  /// Called once a second. Reads whatever state the page depends on.
  func refresh()
  func page(icons: IconStore) -> Page
  func handleTap(_ id: String)
  /// `key` is 1 or 2, `action` "click" or "long".
  func handleKey(_ key: Int, action: String)
}

extension HubContext {
  func handleKey(_ key: Int, action: String) {}
}

enum Palette {
  static let tile = "#263238"
  static let on = "#2E7D32"
  static let off = "#C62828"
  static let unknown = "#455A64"
  static let text = "#FFFFFF"
  static let muted = "#90A4AE"
}
