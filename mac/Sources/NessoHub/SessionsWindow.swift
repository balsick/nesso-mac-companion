import AppKit
import SwiftUI

/// A small window that floats over every other one, in every Space, with the
/// Claude sessions the Nesso shows: a picture in picture for when the Nesso is
/// busy with a call, or out of sight. Clicking a session opens it, as tapping
/// it on the Nesso does.
///
/// It never takes the focus: a click opens the session without bringing
/// Nesso Hub forward first.
///
/// Compact, it shrinks to the three counters: a click on one still opens the
/// most urgent session it counts.
final class SessionsWindow: NSObject, NSWindowDelegate {
  private let claude: ClaudeContext
  private let onVisibilityChange: (Bool) -> Void
  private let onCompactChange: (Bool) -> Void
  private var panel: NSPanel?
  private var content: SessionsHostingView?
  private(set) var compact: Bool

  private static let frameName = "Sessions"

  var isVisible: Bool { panel?.isVisible ?? false }

  init(claude: ClaudeContext, compact: Bool, onVisibilityChange: @escaping (Bool) -> Void,
       onCompactChange: @escaping (Bool) -> Void) {
    self.claude = claude
    self.compact = compact
    self.onVisibilityChange = onVisibilityChange
    self.onCompactChange = onCompactChange
    super.init()
    claude.onRefresh = { [weak self] in self?.update() }
  }

  func toggleCompact() {
    compact.toggle()
    onCompactChange(compact)
    guard let panel, let content else { return }
    let old = panel.frame
    update()
    // Resized now rather than by the hosting view, to choose which corner
    // stays put: the title bar keeps its height, and on the right half of the
    // screen the right edge stays too, so that the window shrinks toward the
    // side of the screen it sits on.
    var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
    let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? old
    frame.origin.x = old.midX > screen.midX ? old.maxX - frame.width : old.minX
    frame.origin.y = old.maxY - frame.height
    panel.setFrame(frame, display: true)
  }

  func toggle() {
    if isVisible { panel?.close() } else { show() }
  }

  func show() {
    if panel == nil { makePanel() }
    update()
    panel?.orderFrontRegardless()
    onVisibilityChange(true)
  }

  func windowWillClose(_ notification: Notification) {
    onVisibilityChange(false)
  }

  /// The window follows its content's height, and keeps its title bar where
  /// it was put.
  private func update() {
    content?.rootView = view()
  }

  private func view() -> SessionsView {
    SessionsView(sessions: claude.list, now: Date(), compact: compact,
                 open: { [weak self] in self?.claude.open($0) },
                 toggleCompact: { [weak self] in self?.toggleCompact() })
  }

  private func makePanel() {
    let content = SessionsHostingView(rootView: view())
    // Already the content's size: a window placed while empty is moved
    // elsewhere once it grows.
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.title = "Claude"
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.contentView = content
    // Top right of the screen in use the first time, then wherever it was
    // left.
    if !panel.setFrameUsingName(Self.frameName), let screen = NSScreen.main?.visibleFrame {
      panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.maxY - 16))
    }
    panel.setFrameAutosaveName(Self.frameName)
    self.panel = panel
    self.content = content
  }
}

/// One click opens a session, even while the window is not the key one.
private final class SessionsHostingView: NSHostingView<SessionsView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

/// The counters of the Nesso's Claude page, then one line per session, most
/// urgent first, with how long it has been in its state. Compact, the
/// counters alone.
struct SessionsView: View {
  let sessions: [ClaudeSessions.Session]
  let now: Date
  var compact = false
  var open: (ClaudeSessions.Session) -> Void = { _ in }
  var toggleCompact: () -> Void = {}

  static let width: CGFloat = 260
  /// Room for two digits in every counter, so that the window does not change
  /// width with the counts.
  static let compactWidth: CGFloat = 208
  /// Any more and the window is no longer small.
  private static let maxLines = 10

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        counter(.waiting, symbol: "hand.raised.fill")
        counter(.done, symbol: "checkmark")
        counter(.working, symbol: "ellipsis")
        Spacer(minLength: 0)
        CompactToggle(compact: compact, action: toggleCompact)
      }
      if !compact { list }
    }
    .padding(10)
    .frame(width: compact ? Self.compactWidth : Self.width, alignment: .leading)
  }

  @ViewBuilder private var list: some View {
    if sessions.isEmpty {
      Text("No session open.").font(.callout).foregroundStyle(.secondary)
    } else {
      VStack(spacing: 1) {
        ForEach(sessions.prefix(Self.maxLines), id: \.key) { session in
          SessionLine(session: session, age: Self.age(since: session.since, now: now)) { open(session) }
        }
      }
      if sessions.count > Self.maxLines {
        Text("and \(sessions.count - Self.maxLines) more").font(.caption).foregroundStyle(.secondary)
          .padding(.leading, 8)
      }
    }
  }

  /// Opens the most urgent session in that state, like a counter on the Nesso.
  private func counter(_ state: ClaudeSessions.Session.State, symbol: String) -> some View {
    let matching = sessions.filter { $0.state == state }
    return Button { matching.first.map(open) } label: {
      HStack(spacing: 4) {
        Image(systemName: symbol).font(.system(size: 10, weight: .bold))
        Text("\(matching.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
      }
      .foregroundStyle(matching.isEmpty ? Color.secondary : .white)
      .padding(.horizontal, 9)
      .frame(height: 22)
      .background(Capsule().fill(matching.isEmpty ? Color.secondary.opacity(0.12) : state.colour))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(matching.isEmpty)
  }

  static func age(since: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(since) / 60)
    if minutes < 1 { return "now" }
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 48 * 60 { return "\(minutes / 60)h" }
    return "\(minutes / (24 * 60))d"
  }
}

private struct SessionLine: View {
  let session: ClaudeSessions.Session
  let age: String
  let open: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: open) {
      HStack(spacing: 8) {
        Circle().fill(session.state.colour).frame(width: 8, height: 8)
        Text(session.name).lineLimit(1).truncationMode(.tail)
          .foregroundStyle(session.state == .idle ? Color.secondary : .primary)
        Spacer(minLength: 4)
        Text(age).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
      }
      .font(.system(size: 12))
      .padding(.horizontal, 8)
      .frame(height: 24)
      .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.secondary.opacity(0.15) : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

/// The chevron at the end of the counters: up folds the list away, down
/// brings it back.
private struct CompactToggle: View {
  let compact: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: compact ? "chevron.down" : "chevron.up")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.secondary.opacity(0.15) : .clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(compact ? "Show the sessions" : "Show the counters only")
  }
}

private extension ClaudeSessions.Session.State {
  /// The colours of the Nesso's Claude page and of the LEDs.
  var colour: Color {
    switch self {
    case .waiting: return .orange
    case .done: return .green
    case .working: return .blue
    case .idle: return .gray
    }
  }
}
