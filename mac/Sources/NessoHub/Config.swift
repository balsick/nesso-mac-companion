import Foundation

/// ~/.config/nesso-hub/config.json. Written with the defaults on first run so
/// there is something to edit.
struct Config: Codable {
  /// Reactions shown on the Meet page, in order. Any emoji in Meet's picker
  /// can be sent; the ones not in its quick bar are found through its search.
  var reactions: [String] = ["💖", "👍", "🎉", "👏", "😂", "😮"]

  /// The reactions in Meet's quick bar, in Meet's order. The Reactions window
  /// lists them first.
  static let meetReactions = ["💖", "👍", "🎉", "👏", "😂", "😮", "😢", "🤔", "👎"]
  /// Three rows of three is all the Meet page has room for under the toggles.
  static let maxReactions = 9
  /// The Chromium browser that runs Meet. Chrome, Edge and Brave all take the
  /// same AppleScript.
  var browser: String = "com.google.Chrome"

  /// Reactions sent on their own when someone joins a given meeting.
  var automations: [Automation] = []

  /// "When `joins` joins the meeting called `title` (or with code `code`),
  /// send `react`", once per meeting. Either `title` or `code` is enough to
  /// recognise the meeting; the title survives the code changing.
  struct Automation: Codable, Equatable {
    var title: String?
    var code: String?
    var joins: String
    var react: String

    func matches(code callCode: String?, title callTitle: String?) -> Bool {
      if let code, let callCode, code.caseInsensitiveCompare(callCode) == .orderedSame { return true }
      if let title, let callTitle, callTitle.localizedCaseInsensitiveContains(title) { return true }
      return false
    }
  }

  init() {}

  /// Every key is optional, so a config written by an older version still
  /// loads, with the defaults for what it lacks.
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Config()
    reactions = try values.decodeIfPresent([String].self, forKey: .reactions) ?? defaults.reactions
    browser = try values.decodeIfPresent(String.self, forKey: .browser) ?? defaults.browser
    automations = try values.decodeIfPresent([Automation].self, forKey: .automations) ?? defaults.automations
  }

  static let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/nesso-hub/config.json")

  static func load() -> Config {
    if let data = try? Data(contentsOf: url) {
      do {
        return try JSONDecoder().decode(Config.self, from: data)
      } catch {
        log("config", "\(url.path) is invalid, using defaults: \(error)")
        return Config()
      }
    }
    let config = Config()
    config.save()
    log("config", "wrote defaults to \(url.path)")
    return config
  }

  func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    do {
      try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(self).write(to: Self.url, options: .atomic)
    } catch {
      log("config", "could not save \(Self.url.path): \(error)")
    }
  }
}

/// Where the log goes however the app was started: from run.sh, the Finder or
/// at login.
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nesso Hub.log")

private let logFile: FileHandle? = {
  if !FileManager.default.fileExists(atPath: logURL.path) {
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
  }
  let handle = try? FileHandle(forWritingTo: logURL)
  handle?.seekToEndOfFile()
  return handle
}()

func log(_ area: String, _ message: String) {
  let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
  let line = Data("\(time) [\(area)] \(message)\n".utf8)
  FileHandle.standardError.write(line)
  logFile?.write(line)
}
