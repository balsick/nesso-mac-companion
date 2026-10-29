import Foundation

/// Ties the link to the contexts: picks which one owns the screen, sends its
/// page when it changes, and routes taps and keys back to it.
final class Hub {
  private let link: Link
  private let icons = IconStore()
  private let contexts: [HubContext]
  private var current: HubContext?
  /// Fires when the active context changes, for the menu bar.
  var onContextChange: (() -> Void)?
  var contextName: String { current?.name ?? "-" }
  private var lastPage: String?
  private var timer: Timer?

  init(link: Link, contexts: [HubContext]) {
    self.link = link
    self.contexts = contexts.sorted { $0.priority > $1.priority }

    for context in contexts {
      context.onChange = { [weak self] in self?.render() }
    }
    link.onReady = { [weak self] in
      self?.lastPage = nil
      self?.link.send(#"{"t":"hello"}"#)
      self?.render()
    }
    link.onLost = { [weak self] in self?.lastPage = nil }
    link.onLine = { [weak self] line in self?.handle(line) }
  }

  func start() {
    // No tick straight away: the first AppleScript call can sit on the
    // Automation prompt, and Bluetooth should get to ask for its own first.
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
  }

  private func tick() {
    contexts.forEach { $0.refresh() }
    render()
  }

  private func render() {
    guard let active = contexts.first(where: { $0.isActive }) else { return }
    if active !== current {
      log("hub", "context: \(active.name)")
      current = active
      onContextChange?()
    }
    guard link.isReady else { return }
    let page = Wire.encode(active.page(icons: icons))
    if page != lastPage {
      lastPage = page
      link.send(page)
    }
  }

  private func handle(_ line: String) {
    guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else {
      log("hub", "bad line from the Nesso: \(line)")
      return
    }
    switch event.t {
    case "hello":
      log("hub", "Nesso firmware \(event.fw ?? "?"), protocol \(event.proto ?? 0)")
      if event.proto != Wire.version { log("hub", "protocol mismatch: the Mac speaks \(Wire.version)") }
    case "tap":
      guard let id = event.id else { return }
      log("hub", "tap \(id) -> \(current?.name ?? "-")")
      current?.handleTap(id)
    case "key":
      guard let key = event.k.flatMap(Int.init), let action = event.a else { return }
      log("hub", "key \(key) \(action) -> \(current?.name ?? "-")")
      current?.handleKey(key, action: action)
    case "need":
      for id in event.ids ?? [] {
        if let icon = icons.line(for: id) { link.send(icon) } else { log("hub", "Nesso asked for unknown icon \(id)") }
      }
    default:
      log("hub", "unknown message \(event.t)")
    }
  }
}
