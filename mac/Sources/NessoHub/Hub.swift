import Foundation

/// Ties the link to the contexts: picks which one owns the screen, sends its
/// page when it changes, and routes taps and keys back to it.
final class Hub {
  private let link: Link
  private let icons = IconStore()
  private let contexts: [HubContext]
  private let indicator: HubIndicator?
  private var current: HubContext?
  /// Fires when the active context changes, for the menu bar.
  var onContextChange: (() -> Void)?
  var contextName: String { current?.name ?? "-" }
  private var lastPage: String?
  private var lastPixels: String?
  private var timer: Timer?
  /// As the Nesso last said it is turned.
  private var screen = Screen.upright

  init(link: Link, contexts: [HubContext], indicator: HubIndicator? = nil) {
    self.link = link
    self.contexts = contexts.sorted { $0.priority > $1.priority }
    self.indicator = indicator

    for context in contexts {
      context.onChange = { [weak self] in self?.render() }
    }
    link.onReady = { [weak self] in
      self?.lastPage = nil
      self?.lastPixels = nil
      self?.link.send(#"{"t":"hello"}"#)
      self?.render()
    }
    link.onLost = { [weak self] in
      self?.lastPage = nil
      self?.lastPixels = nil
    }
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
    send(Wire.encode(active.page(icons: icons, screen: screen)), last: &lastPage)
    if let indicator { send(Wire.encode(indicator.pixels()), last: &lastPixels) }
  }

  /// Sends `line` unless it is what was sent last.
  private func send(_ line: String, last: inout String?) {
    guard line != last else { return }
    last = line
    link.send(line)
  }

  private func handle(_ line: String) {
    guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else {
      log("hub", "bad line from the Nesso: \(line)")
      return
    }
    switch event.t {
    case "hello":
      let px = event.px ?? 0
      log("hub", "Nesso firmware \(event.fw ?? "?"), protocol \(event.proto ?? 0), \(px > 0 ? "\(px) pixels" : "no pixels")")
      if event.proto != Wire.version { log("hub", "protocol mismatch: the Mac speaks \(Wire.version)") }
      turned(event)
    case "screen":
      turned(event)
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

  /// Lays the page out again when the Nesso's screen has turned.
  private func turned(_ event: Event) {
    guard let w = event.w, let h = event.h, w > 0, h > 0 else { return }
    let size = Screen(w: w, h: h)
    guard size != screen else { return }
    log("hub", "screen \(w)x\(h)")
    screen = size
    lastPage = nil
    render()
  }
}
