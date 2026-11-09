import Foundation

/// Claude Code sessions: the ones that wait for you, the ones that finished
/// while you were looking elsewhere, the ones still working, and the ones
/// open with nothing new.
///
/// Takes the screen whenever a session is open and no call is on, and drives
/// the Modulino Pixels all the time, call or not: one LED per session, most
/// urgent first. Tapping a session, or a counter, opens it; KEY1 opens
/// the most urgent one, KEY2 shows the next page of sessions.
final class ClaudeContext: HubContext, HubIndicator {
  let name = "claude"
  let priority = 50
  var onChange: (() -> Void)?
  /// Fires after every refresh, for the sessions window.
  var onRefresh: (() -> Void)?

  private let sessions: ClaudeSessions
  private let config: Config.Claude
  /// Most urgent first.
  private(set) var list: [ClaudeSessions.Session] = []
  private var pageIndex = 0
  private var now = Date()
  /// The one the last page was laid out for, so KEY2 pages the same way.
  private var screen = Screen.upright

  /// What fits under the counters: five rows upright, two rows of two on
  /// its side.
  private var perPage: Int { screen.isWide ? 4 : 5 }

  init(config: Config.Claude) {
    self.config = config
    sessions = ClaudeSessions(cloud: config.cloud)
  }

  var isActive: Bool { config.enabled && !list.isEmpty }

  /// For the menu bar.
  var summary: String {
    guard config.enabled else { return "off" }
    let parts = [(ClaudeSessions.Session.State.waiting, "waiting"), (.done, "done"), (.working, "working"),
                 (.idle, "idle")]
      .compactMap { state, word in count(state) > 0 ? "\(count(state)) \(word)" : nil }
    let cloud = sessions.cloud?.problem.map { " (cloud: \($0))" } ?? ""
    return (parts.isEmpty ? "nothing running" : parts.joined(separator: ", ")) + cloud
  }

  func refresh() {
    now = Date()
    guard config.enabled else { return }
    sessions.refresh()
    list = sessions.sessions
    onRefresh?()
  }

  func page(icons: IconStore, screen: Screen) -> Page {
    self.screen = screen
    let pages = max(1, (list.count + perPage - 1) / perPage)
    pageIndex = min(pageIndex, pages - 1)

    var rows = [Row(h: 44, tiles: [
      counter(.waiting, symbol: "hand.raised.fill", icons: icons),
      counter(.done, symbol: "checkmark", icons: icons),
      counter(.working, symbol: "ellipsis", icons: icons),
    ])]
    let shown = Array(list.dropFirst(pageIndex * perPage).prefix(perPage))
    if screen.isWide {
      // An empty black tile keeps a lone session in the last row at half width.
      for start in stride(from: 0, to: shown.count, by: 2) {
        let pair = shown[start..<min(start + 2, shown.count)].map { tile($0, maxLength: 16) }
        rows.append(Row(h: 22, tiles: pair.count == 2 ? pair : pair + [Tile(bg: "#000000")]))
      }
    } else {
      for session in shown {
        rows.append(Row(h: 26, tiles: [tile(session, maxLength: 18)]))
      }
    }

    let time = now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    return Page(title: "Claude", sub: pages > 1 ? "\(time)   \(pageIndex + 1)/\(pages)" : time,
                accent: "#D97757", rows: rows)
  }

  func handleTap(_ id: String) {
    if id.hasPrefix("s:") {
      let key = String(id.dropFirst(2))
      if let session = list.first(where: { $0.key == key }) { open(session) }
    } else if id.hasPrefix("c:"), let raw = Int(id.dropFirst(2)), let state = ClaudeSessions.Session.State(rawValue: raw),
              let session = list.first(where: { $0.state == state }) {
      open(session)
    }
  }

  func handleKey(_ key: Int, action: String) {
    guard action == "click" else { return }
    if key == 1, let session = list.first {
      open(session)
    } else if key == 2, list.count > perPage {
      pageIndex = (pageIndex + 1) % ((list.count + perPage - 1) / perPage)
      onChange?()
    }
  }

  func pixels() -> Pixels {
    guard config.enabled else { return Pixels(b: 0, leds: []) }
    let leds = list.prefix(8).map { session -> Pixels.Led in
      switch session.state {
      case .waiting: return Pixels.Led(c: "#FF5A00", fx: "blink")
      case .done: return Pixels.Led(c: "#00E040")
      case .working: return Pixels.Led(c: "#0050FF", fx: "pulse")
      // Just enough to tell the session is there.
      case .idle: return Pixels.Led(c: "#303030")
      }
    }
    return Pixels(b: min(max(config.brightness, 1), 31), leds: Array(leds))
  }

  // MARK: Pieces

  func open(_ session: ClaudeSessions.Session) {
    log("claude", "opening \(session.name)")
    sessions.open(session)
  }

  private func count(_ state: ClaudeSessions.Session.State) -> Int {
    list.filter { $0.state == state }.count
  }

  private func counter(_ state: ClaudeSessions.Session.State, symbol: String, icons: IconStore) -> Tile {
    let n = count(state)
    return Tile(id: "c:\(state.rawValue)", label: "\(n)", icon: icons.symbol(symbol, size: 18),
                bg: n > 0 ? Self.screenColour(state) : Palette.tile, fg: n > 0 ? Palette.text : Palette.muted,
                font: "m")
  }

  private static func screenColour(_ state: ClaudeSessions.Session.State) -> String {
    switch state {
    case .waiting: return "#E65100"
    case .done: return Palette.on
    case .working: return "#1565C0"
    case .idle: return Palette.tile
    }
  }

  private func tile(_ session: ClaudeSessions.Session, maxLength: Int) -> Tile {
    Tile(id: "s:\(session.key)", label: short(session.name, maxLength: maxLength),
         bg: Self.screenColour(session.state), fg: session.state == .idle ? Palette.muted : Palette.text, font: "s")
  }

  /// A 127px tile holds about eighteen characters of the small font, fewer
  /// in capitals; the 114px ones on its side about sixteen.
  private func short(_ name: String, maxLength: Int) -> String {
    let name = asciiLabel(name)
    return name.count > maxLength ? name.prefix(maxLength - 2).trimmingCharacters(in: .whitespaces) + ".." : name
  }
}
