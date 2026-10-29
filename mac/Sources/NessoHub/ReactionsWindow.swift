import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The window behind "Choose Reactions…": pick which emoji the Nesso shows and
/// in what order, from every emoji Meet's picker offers, with a preview of the
/// Nesso's screen.
/// Every change is saved and pushed to the Nesso straight away.
final class ReactionsWindow {
  private let model: ReactionsModel
  private var window: NSWindow?

  init(reactions: [String], onChange: @escaping ([String]) -> Void) {
    model = ReactionsModel(selected: reactions, onChange: onChange)
  }

  func show() {
    if window == nil {
      let window = NSWindow(contentViewController: NSHostingController(rootView: ReactionsView(model: model)))
      window.title = "Nesso Hub Reactions"
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      self.window = window
    }
    // A menu bar app has to bring itself forward, or the window opens behind
    // whatever app is in front.
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
}

final class ReactionsModel: ObservableObject {
  @Published var selected: [String] {
    didSet { if selected != oldValue { onChange(selected) } }
  }
  /// The reaction being dragged, so the grid can reorder while it moves.
  @Published var dragging: String?

  @Published var query = ""
  private let onChange: ([String]) -> Void

  init(selected: [String], onChange: @escaping ([String]) -> Void) {
    self.selected = Array(selected.prefix(Config.maxReactions))
    self.onChange = onChange
  }

  var results: [EmojiCatalog.Entry] { EmojiCatalog.search(query) }
  var isFull: Bool { selected.count >= Config.maxReactions }

  func toggle(_ emoji: String) {
    if let index = selected.firstIndex(of: emoji) {
      selected.remove(at: index)
    } else if !isFull {
      selected.append(emoji)
    }
  }

  func move(_ emoji: String, before target: String) {
    guard emoji != target, let from = selected.firstIndex(of: emoji),
          let to = selected.firstIndex(of: target) else { return }
    selected.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
  }
}

// MARK: - Views

struct ReactionsView: View {
  @ObservedObject var model: ReactionsModel
  /// For `nesso-hub render-reactions`: ImageRenderer cannot draw scroll views.
  var snapshot = false

  private let columns = Array(repeating: GridItem(.fixed(56), spacing: 10), count: 3)

  var body: some View {
    HStack(alignment: .top, spacing: 28) {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          Text("On the Nesso").font(.headline)
          Text("Click to remove, drag to reorder.").font(.callout).foregroundStyle(.secondary)
        }
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
          ForEach(model.selected, id: \.self) { emoji in
            EmojiChip(emoji: emoji, style: .selected)
              .help(EmojiCatalog.name(of: emoji))
              .opacity(model.dragging == emoji ? 0.3 : 1)
              .onTapGesture { withAnimation(.snappy) { model.toggle(emoji) } }
              .onDrag {
                model.dragging = emoji
                return NSItemProvider(object: emoji as NSString)
              }
              .onDrop(of: [.text], delegate: ReorderDelegate(target: emoji, model: model))
          }
          ForEach(0..<max(0, Config.maxReactions - model.selected.count), id: \.self) { _ in
            EmojiChip(emoji: nil, style: .empty)
          }
        }

        Spacer(minLength: 0)
      }
      .frame(width: 188)

      EmojiPicker(model: model, snapshot: snapshot)
        .frame(width: 300)

      VStack(spacing: 10) {
        NessoPreview(reactions: model.selected)
        Text("Preview during a call").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(24)
    .fixedSize()
  }
}

/// Every emoji, searchable by its English or Italian name.
struct EmojiPicker: View {
  @ObservedObject var model: ReactionsModel
  var snapshot = false
  private let columns = [GridItem(.adaptive(minimum: 38), spacing: 4)]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("All emoji").font(.headline)
        Text(model.isFull ? "All nine slots are taken: remove one first." : "Click to add or remove.")
          .font(.callout).foregroundStyle(.secondary)
      }
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search, e.g. pizza, gatto or :+1:", text: $model.query)
          .textFieldStyle(.plain)
        if !model.query.isEmpty {
          Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
      }
      .padding(7)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))

      if snapshot {
        grid(Array(model.results.prefix(40)))
      } else {
        ScrollView { grid(model.results) }.frame(height: 330)
      }
    }
  }

  private var quickBar: Set<String> { Set(Config.meetReactions) }

  /// All of them, or a taste of each group for a snapshot.
  private var groups: [EmojiCatalog.Group] {
    snapshot ? EmojiCatalog.groups.prefix(2).map { EmojiCatalog.Group(name: $0.name, entries: Array($0.entries.prefix(14))) }
      : EmojiCatalog.groups
  }

  private func grid(_ results: [EmojiCatalog.Entry]) -> some View {
    VStack {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
          if model.query.isEmpty {
            Section(header: header("Meet's quick bar")) {
              ForEach(Config.meetReactions, id: \.self) { cell($0) }
            }
            // Meet's own groups, without the quick bar's emoji: a grid cannot
            // show one id twice.
            ForEach(groups) { group in
              Section(header: header(group.name)) {
                ForEach(group.entries.filter { !quickBar.contains($0.emoji) }) { cell($0.emoji) }
              }
            }
          } else {
            ForEach(results) { cell($0.emoji) }
          }
        }
        if results.isEmpty {
          Text("No emoji called \u{201C}\(model.query)\u{201D}.").font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.top, 30)
        }
    }
  }

  private func header(_ title: String) -> some View {
    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 6)
  }

  private func cell(_ emoji: String) -> some View {
    let chosen = model.selected.contains(emoji)
    return Text(emoji).font(.system(size: 24))
      .frame(width: 38, height: 38)
      .background(RoundedRectangle(cornerRadius: 8).fill(chosen ? Color.accentColor.opacity(0.22) : .clear))
      .opacity(!chosen && model.isFull ? 0.35 : 1)
      .contentShape(Rectangle())
      .onTapGesture { withAnimation(.snappy) { model.toggle(emoji) } }
      .help(EmojiCatalog.name(of: emoji))
  }
}

struct EmojiChip: View {
  enum Style { case selected, empty }
  let emoji: String?
  let style: Style

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(style == .selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(style == .empty ? Color.secondary.opacity(0.3) : .clear,
                      style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      if let emoji { Text(emoji).font(.system(size: 30)) }
    }
    .frame(width: 56, height: 56)
    .contentShape(Rectangle())
  }
}

struct ReorderDelegate: DropDelegate {
  let target: String
  let model: ReactionsModel

  func dropEntered(info: DropInfo) {
    guard let dragging = model.dragging else { return }
    withAnimation(.snappy) { model.move(dragging, before: target) }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

  func performDrop(info: DropInfo) -> Bool {
    model.dragging = nil
    return true
  }
}

/// The Nesso's Meet page, laid out with the same numbers as MeetContext and
/// the firmware, scaled up.
struct NessoPreview: View {
  let reactions: [String]
  private let scale: CGFloat = 1.6

  private func hex(_ value: UInt32) -> Color {
    Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
          blue: Double(value & 0xFF) / 255)
  }

  private var rowCount: Int { (reactions.count + 2) / 3 }

  private var rowHeight: CGFloat {
    guard rowCount > 0 else { return 0 }
    return CGFloat(min(48, (Wire.screenHeight - 20 - 14 - 4 - 80 - 4 * rowCount) / rowCount))
  }

  var body: some View {
    let width = CGFloat(Wire.screenWidth), height = CGFloat(Wire.screenHeight)
    screen
      .frame(width: width, height: height)
      .background(Color.black)
      .scaleEffect(scale)
      .frame(width: width * scale, height: height * scale)
      .padding(14)
      .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(hex(0xECEFF1)))
      .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
      .animation(.snappy, value: reactions)
  }

  private var screen: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Text("in call").font(.system(size: 7, design: .monospaced)).foregroundStyle(.gray)
        .padding(.horizontal, 5).frame(height: 14)
      VStack(spacing: 4) {
        HStack(spacing: 4) {
          toggleTile("mic.fill", "MIC")
          toggleTile("video.fill", "CAM")
        }
        .frame(height: 76)
        ForEach(0..<rowCount, id: \.self) { row in reactionRow(row) }
      }
      .padding(.horizontal, 4)
      .padding(.top, 4)
      Spacer(minLength: 0)
    }
  }

  private var header: some View {
    HStack {
      Text("Meet").font(.system(size: 11, weight: .bold)).foregroundStyle(hex(0x00BFA5))
      Spacer()
      Text("100%").font(.system(size: 7, design: .monospaced)).foregroundStyle(hex(0x1EA0AA))
    }
    .padding(.horizontal, 5)
    .frame(height: 20)
    .background(hex(0x212429))
  }

  private func reactionRow(_ row: Int) -> some View {
    let emojis = Array(reactions[(row * 3)..<min(row * 3 + 3, reactions.count)])
    let size = min(32, rowHeight - 10) * 0.85
    return HStack(spacing: 4) {
      ForEach(emojis, id: \.self) { emoji in
        RoundedRectangle(cornerRadius: 8).fill(hex(0x263238))
          .overlay(Text(emoji).font(.system(size: size)))
      }
    }
    .frame(height: rowHeight)
  }

  private func toggleTile(_ symbol: String, _ label: String) -> some View {
    RoundedRectangle(cornerRadius: 8).fill(hex(0x2E7D32))
      .overlay(VStack(spacing: 3) {
        Image(systemName: symbol).font(.system(size: 24, weight: .bold))
        Text(label).font(.system(size: 9, weight: .bold))
      }.foregroundStyle(.white))
  }
}
