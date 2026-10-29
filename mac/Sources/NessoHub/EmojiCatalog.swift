import Foundation

/// The emoji in Meet's picker, in its groups and order, with the shortcodes
/// its search understands (`:United-Kingdom-flag:`).
///
/// The layout and shortcodes are Google's own emoji picker metadata, bundled
/// from Resources/emoji-metadata. Names for searching in English and Italian
/// come from the Character Viewer's data in macOS; that file is private to
/// macOS, so without it search falls back to the shortcodes alone.
enum EmojiCatalog {
  struct Entry: Identifiable, Hashable {
    /// Spelled the way macOS spells it where it knows the emoji, so it renders
    /// as an emoji (with U+FE0F) rather than as text.
    let emoji: String
    let name: String
    let localizedName: String?
    /// Without the colons: "United-Kingdom-flag".
    let shortcodes: [String]
    var id: String { emoji }
  }

  struct Group: Identifiable {
    let name: String
    let entries: [Entry]
    var id: String { name }
  }

  static let groups: [Group] = load()
  static let all: [Entry] = groups.flatMap(\.entries)

  private static let byBareEmoji: [String: Entry] =
    Dictionary(all.map { (bare($0.emoji), $0) }, uniquingKeysWith: { a, _ in a })

  static func entry(for emoji: String) -> Entry? { byBareEmoji[bare(emoji)] }

  static func name(of emoji: String) -> String {
    if let entry = entry(for: emoji) { return entry.name }
    let unicode = emoji.applyingTransform(.toUnicodeName, reverse: false) ?? emoji
    return unicode.replacingOccurrences(of: "\\N{", with: "").replacingOccurrences(of: "}", with: " ")
      .trimmingCharacters(in: .whitespaces).lowercased()
  }

  /// Entries whose names or shortcodes contain every word of `query`.
  static func search(_ query: String) -> [Entry] {
    // Colons are shortcode punctuation, so ":+1:" finds 👍.
    let words = query.lowercased().replacingOccurrences(of: ":", with: " ").split(separator: " ").map(String.init)
    guard !words.isEmpty else { return all }
    return all.filter { entry in
      let haystack = ([entry.name, entry.localizedName ?? ""] + entry.shortcodes).joined(separator: " ").lowercased()
      return words.allSatisfy(haystack.contains)
    }
  }

  /// What to type into Meet's emoji search, best guess first: Meet's own
  /// shortcode, then for an emoji Google's data does not know, the macOS name
  /// rewritten the way Google words names, its significant words, its
  /// longest word.
  static func searchTerms(for emoji: String) -> [String] {
    let name = name(of: emoji)
    let stopWords: Set<String> = ["of", "the", "and", "&", "a", "in", "with"]
    let significant = name.split(separator: " ").map(String.init).filter { !stopWords.contains($0.lowercased()) }
    let candidates: [String?] = (entry(for: emoji)?.shortcodes ?? []) + [
      shortcode(for: name), significant.joined(separator: " "), significant.max { $0.count < $1.count },
    ]
    var seen = Set<String>()
    return candidates.compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }

  /// Google's shortcodes put "flag" last and join words with hyphens:
  /// "flag of the United Kingdom" is `United-Kingdom-flag`.
  static func shortcode(for name: String) -> String {
    var words = name.split(separator: " ").map(String.init)
    if words.first == "flag", words.count > 1 {
      words.removeFirst()
      while let first = words.first, first == "of" || first == "the" { words.removeFirst() }
      words.append("flag")
    }
    return words.joined(separator: "-")
  }

  // MARK: Loading

  private struct GoogleGroup: Decodable {
    let group: String
    let emoji: [GoogleEmoji]
  }

  private struct GoogleEmoji: Decodable {
    let base: [UInt32]
    let shortcodes: [String]
  }

  private static func load() -> [Group] {
    let english = appleNames(in: "en")
    let italian = appleNames(in: "it")
    // macOS spells some emoji with U+FE0F where Google's code points do not.
    let appleSpelling = Dictionary(english.keys.map { (bare($0), $0) }, uniquingKeysWith: { a, _ in a })

    guard let url = Bundle.main.url(forResource: "emoji-ordering", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let google = try? JSONDecoder().decode([GoogleGroup].self, from: data) else {
      log("emoji", "no emoji-ordering.json in the app bundle; listing macOS's emoji instead")
      let entries = english.keys.sorted {
        $0.unicodeScalars.map(\.value).lexicographicallyPrecedes($1.unicodeScalars.map(\.value))
      }
      .map { Entry(emoji: $0, name: english[$0]!, localizedName: italian[$0], shortcodes: []) }
      return [Group(name: "Everything", entries: entries)]
    }

    return google.map { group in
      Group(name: group.group, entries: group.emoji.map { item in
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: item.base.compactMap(Unicode.Scalar.init))
        let googleSpelling = String(scalars)
        let emoji = appleSpelling[bare(googleSpelling)] ?? googleSpelling
        let codes = item.shortcodes.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ":")) }
        let name = english[emoji] ?? codes.first?.replacingOccurrences(of: "-", with: " ") ?? emoji
        return Entry(emoji: emoji, name: name, localizedName: italian[emoji], shortcodes: codes)
      })
    }
  }

  /// Without U+FE0F, so both spellings of an emoji meet.
  private static func bare(_ emoji: String) -> String {
    String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
  }

  private static func appleNames(in language: String) -> [String: String] {
    let path = "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources/\(language).lproj/AppleName.strings"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
    else {
      if language == "en" { log("emoji", "no emoji names at \(path)") }
      return [:]
    }
    return plist
  }
}
