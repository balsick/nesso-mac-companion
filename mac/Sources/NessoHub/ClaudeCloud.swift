import CryptoKit
import Foundation
import Security

/// The Code sessions the Mac does not run itself: the ones in the cloud, and
/// the ones another computer runs under Remote Control. Nothing on the Mac
/// knows what they are doing, so they come from the API Claude Code lists them
/// with, signed in with Claude Code's own tokens from the keychain. Like the
/// files ClaudeSessions reads, the API is not documented, so every field is
/// optional.
///
/// A token answers for the organisation its login chose, so a Claude app
/// profile signed in to another one needs a login of its own: Claude Code run
/// with another CLAUDE_CONFIG_DIR keeps its login in a keychain item of its
/// own, next to the default one. Every "Claude Code-credentials…" item is
/// used, and the lists are merged.
///
/// A token lasts a few hours, and only Claude Code renews it, when it runs
/// with that login's folder: the Claude app gives its sessions a token of its
/// own. So when a token is about to expire, Nesso Hub runs `claude mcp list`
/// with its folder. Loading the organisation's claude.ai connectors, Claude
/// Code checks the token first and renews it, under its own lock. Renewing it
/// here instead would spend the refresh token behind Claude Code's back.
///
/// Reading another app's keychain item can make macOS ask for permission, on
/// every read unless it was told "Always Allow". So a token is kept once read,
/// and its item is read again only when the token has expired or the API
/// refuses it, and not more than every ten minutes; once the user says no,
/// not until Nesso Hub restarts. Listing the items reads only their names,
/// which asks nothing. The reads and the requests run off the main thread,
/// since a prompt blocks the read until it is answered.
final class ClaudeCloud {
  struct Remote: Equatable {
    var id: String
    var title: String
    /// "running", "idle" or "requires_action".
    var workerStatus: String
    var lastEvent: Date?
    /// Under Remote Control: a session some computer runs, maybe this Mac.
    var bridge: Bool
    /// The keychain item of the login that listed it.
    var login: String
  }

  /// What the last poll found; empty until one succeeds.
  private(set) var sessions: [Remote] = []
  /// Why the last poll missed some or all sessions, for the menu bar.
  private(set) var problem: String?

  private static let interval: TimeInterval = 10
  /// The default login's item; others add a suffix.
  private static let keychainService = "Claude Code-credentials"
  /// Each keychain read can be a prompt, and new logins are rare.
  private static let keychainInterval: TimeInterval = 600
  /// How long before a token expires Claude Code is asked to renew it, and
  /// how often again if it did not.
  private static let renewAhead: TimeInterval = 600
  private static let renewRetry: TimeInterval = 120
  private static let home = FileManager.default.homeDirectoryForCurrentUser
  private static let cli: URL? = ["\(home.path)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    .map(URL.init(fileURLWithPath:))
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  private static let api = URL(string: "https://api.anthropic.com/v1/code/sessions")!
  /// Each page holds 100; more than this many sessions is not a desk's worth.
  private static let maxPages = 5

  private let queue = DispatchQueue(label: "claude-cloud")
  private var polling = false
  private var lastPoll = Date.distantPast
  /// How many sessions the last successful poll found, to log changes.
  private var listed: Int?
  /// Problems already in the log.
  private var logged = Set<String>()

  // Only touched on `queue`.
  private var logins: [Login] = []
  private var lastLoginsRead = Date.distantPast
  private var accounts: [String: Account] = [:]
  /// The recent sessions left out, each logged once.
  private var skipped = Set<String>()

  /// A Claude Code login: its keychain item, and the config folder Claude
  /// Code keeps it for.
  private struct Login: Equatable {
    var service: String
    /// Nil for the default folder, ~/.claude.
    var folder: String?
    /// False when no folder in the home folder goes with the item, so
    /// Claude Code cannot be asked to renew it.
    var renewable: Bool
    /// When the item last changed: a login done again, or a renewal.
    var modified: Date?
  }

  /// One keychain item and what came of reading it.
  private struct Account {
    var token: Token?
    var lastRead = Date.distantPast
    var lastRenewal = Date.distantPast
    var problem: Problem?
    var refused = false
  }

  private struct Token {
    var value: String
    var expiresAt: Date?
    var expired: Bool { expiresAt.map { $0 < Date() } ?? false }
    var due: Bool { expiresAt.map { $0.timeIntervalSinceNow < ClaudeCloud.renewAhead } ?? false }
  }

  struct Problem: Error {
    var message: String
    /// Only a network hiccup keeps the last list: anything else means it
    /// can no longer be trusted.
    var clears = true
    /// The user said no to the keychain prompt.
    var refused = false
    /// The API's answer, when it gave one.
    var status: Int?
    /// A login whose token expired days ago, that nobody uses any more:
    /// logged, but not worth the menu bar.
    var abandoned = false
  }

  /// Starts a poll if the last one is old enough. What it finds lands on the
  /// main thread, for the next `refresh` to return.
  func refresh() {
    guard !polling, Date().timeIntervalSince(lastPoll) >= Self.interval else { return }
    polling = true
    lastPoll = Date()
    queue.async {
      let (found, problems) = self.poll()
      DispatchQueue.main.async {
        self.polling = false
        for problem in problems where !self.logged.contains(problem.message) {
          self.logged.insert(problem.message)
          log("cloud", problem.message)
        }
        self.problem = problems.first { !$0.abandoned }?.message
        if let found {
          if found.count != self.listed { log("cloud", "\(found.count) sessions in the cloud or elsewhere") }
          self.listed = found.count
          self.sessions = found
        } else if problems.contains(where: \.clears) {
          self.sessions = []
        }
      }
    }
  }

  // MARK: Off the main thread

  /// The sessions of every login that answered, or nil if none did, and what
  /// went wrong with the others.
  private func poll() -> ([Remote]?, [Problem]) {
    if Date().timeIntervalSince(lastLoginsRead) >= Self.keychainInterval {
      lastLoginsRead = Date()
      let found = Self.findLogins()
      // A changed item holds another token, maybe of another organisation.
      for login in found where logins.first(where: { $0.service == login.service })?.modified != login.modified {
        accounts[login.service] = nil
      }
      if found.map(\.service) != logins.map(\.service) {
        let names = found.map { "\($0.service) (\($0.folder ?? ($0.renewable ? "~/.claude" : "folder unknown")))" }
        DispatchQueue.main.async { log("cloud", "Claude Code logins: \(names.joined(separator: ", "))") }
      }
      logins = found
    }
    guard !logins.isEmpty else { return (nil, [Problem(message: "Claude Code is not signed in on this Mac")]) }

    var found: [Remote]?
    var problems: [Problem] = []
    for login in logins {
      let result = currentToken(login).flatMap { token in
        list(token: token, login: login.service).mapError { problem -> Problem in
          // Refused: read the item again in a while, in case Claude Code
          // renewed it.
          if problem.status == 401 {
            self.accounts[login.service]?.token = nil
            self.accounts[login.service]?.problem = problem
            self.accounts[login.service]?.lastRead = Date()
          }
          return problem
        }
      }
      switch result {
      case .success(let remotes):
        var merged = found ?? []
        merged += remotes.filter { remote in !merged.contains { $0.id == remote.id } }
        found = merged
      case .failure(var problem):
        if logins.count > 1 { problem.message = "\(login.service): \(problem.message)" }
        problems.append(problem)
      }
    }
    return (found, problems)
  }

  private func currentToken(_ login: Login) -> Result<String, Problem> {
    let service = login.service
    var account = accounts[service] ?? Account()
    defer { accounts[service] = account }

    // About to expire: let Claude Code renew it, then read the item again.
    var renewing: Date??
    if let token = account.token, token.due, login.renewable, !account.refused,
       Date().timeIntervalSince(account.lastRenewal) >= Self.renewRetry, Self.renew(login) {
      account.lastRenewal = Date()
      renewing = .some(token.expiresAt)
      account.token = nil
      account.problem = nil
      account.lastRead = .distantPast
    }
    if let token = account.token {
      if !token.expired { return .success(token.value) }
      // Expired while kept: reading the item again only helps once Claude
      // Code has been asked to renew it, or after a while.
      if renewing == nil, account.problem == nil {
        let until = token.expiresAt?.formatted(.dateTime.day().month().hour().minute()) ?? "?"
        account.problem = Problem(message: "Claude Code's token expired on \(until): Claude Code did not renew it")
        account.lastRead = Date()
      }
    }
    if account.refused {
      return .failure(Problem(message: "not allowed to read Claude Code's token: restart Nesso Hub to be asked again"))
    }
    if let problem = account.problem, Date().timeIntervalSince(account.lastRead) < Self.keychainInterval {
      return .failure(problem)
    }
    account.lastRead = Date()
    switch Self.readToken(service) {
    case .success(let fresh):
      account.token = fresh
      let until = fresh.expiresAt?.formatted(.dateTime.day().month().hour().minute()) ?? "?"
      if case .some(let before) = renewing {
        let renewed = (fresh.expiresAt ?? .distantPast) > (before ?? .distantPast)
        DispatchQueue.main.async {
          log("cloud", renewed ? "\(service): renewed through Claude Code, valid until \(until)"
                               : "\(service): claude mcp list did not renew it, still until \(until)")
        }
      }
      if fresh.expired {
        let abandoned = fresh.expiresAt.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? false
        let how = login.renewable ? "Claude Code did not renew it" : "run claude with its CLAUDE_CONFIG_DIR to renew it"
        account.problem = Problem(message: "Claude Code's token expired on \(until): \(how)", abandoned: abandoned)
        return .failure(account.problem!)
      }
      account.problem = nil
      if renewing == nil { DispatchQueue.main.async { log("cloud", "\(service): token valid until \(until)") } }
      return .success(fresh.value)
    case .failure(let problem):
      account.problem = problem
      account.refused = problem.refused
      return .failure(problem)
    }
  }

  /// Claude Code's keychain items, with the folder each belongs to. Only
  /// their attributes are read, which macOS does not ask about. The default
  /// login's item is "Claude Code-credentials"; another folder's adds "-" and
  /// the first eight hex digits of the SHA-256 of its path, so the folders
  /// that go with them are found among those in the home folder.
  private static func findLogins() -> [Login] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true,
    ]
    var items: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
          let list = items as? [[String: Any]] else { return [] }
    var services: [String: Date?] = [:]
    for item in list {
      guard let service = item[kSecAttrService as String] as? String, service.hasPrefix(keychainService) else { continue }
      services[service] = item[kSecAttrModificationDate as String] as? Date
    }

    let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
    var folders: [String: String] = [:]
    for name in names where name != ".claude" {
      var isFolder: ObjCBool = false
      let path = home.appendingPathComponent(name).path
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { continue }
      let digest = SHA256.hash(data: Data(path.precomposedStringWithCanonicalMapping.utf8))
      folders["\(keychainService)-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)] = path
    }

    return services.keys.sorted().map { service in
      let modified = services[service] ?? nil
      if service == keychainService {
        return Login(service: service, folder: nil, renewable: cli != nil, modified: modified)
      }
      let folder = folders[service]
      return Login(service: service, folder: folder, renewable: folder != nil && cli != nil, modified: modified)
    }
  }

  /// Runs `claude mcp list` for a login, which renews its token if it is
  /// about to expire. False if it could not be run.
  private static func renew(_ login: Login) -> Bool {
    guard let cli else { return false }
    let process = Process()
    process.executableURL = cli
    process.arguments = ["mcp", "list"]
    var environment = ProcessInfo.processInfo.environment
    environment["CLAUDE_CONFIG_DIR"] = login.folder
    process.environment = environment
    process.currentDirectoryURL = home
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do {
      try process.run()
    } catch {
      DispatchQueue.main.async { log("cloud", "cannot run \(cli.path): \(error)") }
      return false
    }
    if done.wait(timeout: .now() + 90) == .timedOut { process.terminate() }
    return true
  }

  /// Claude Code keeps a login in the keychain as JSON:
  /// {"claudeAiOauth": {"accessToken": "…", "expiresAt": <ms>, …}}.
  private static func readToken(_ service: String) -> Result<Token, Problem> {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
      switch status {
      case errSecItemNotFound: return .failure(Problem(message: "Claude Code is not signed in on this Mac"))
      case errSecUserCanceled, errSecAuthFailed:
        return .failure(Problem(message: "not allowed to read Claude Code's token", refused: true))
      default: return .failure(Problem(message: "no access to Claude Code's token (\(status))"))
      }
    }

    struct Stored: Decodable {
      var claudeAiOauth: OAuth?
      struct OAuth: Decodable {
        var accessToken: String?
        var expiresAt: Double?
      }
    }
    guard let oauth = (try? JSONDecoder().decode(Stored.self, from: data))?.claudeAiOauth,
          let value = oauth.accessToken else {
      return .failure(Problem(message: "Claude Code's token does not read"))
    }
    return .success(Token(value: value, expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }))
  }

  private func list(token: String, login: String) -> Result<[Remote], Problem> {
    var found: [Remote] = []
    var cursor: String?
    for _ in 0..<Self.maxPages {
      var components = URLComponents(url: Self.api, resolvingAgainstBaseURL: false)!
      components.queryItems = [URLQueryItem(name: "limit", value: "100")]
      if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
      var request = URLRequest(url: components.url!, timeoutInterval: 15)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("nesso-hub", forHTTPHeaderField: "User-Agent")

      let page: Page
      switch Self.fetch(request) {
      case .success(let value): page = value
      case .failure(let problem): return .failure(problem)
      }
      for session in page.data ?? [] {
        if let remote = Self.remote(session, login: login) {
          found.append(remote)
        } else {
          noteSkipped(session)
        }
      }
      guard page.has_more == true, let next = page.next_cursor else { break }
      cursor = next
    }
    return .success(found)
  }

  private struct Page: Decodable {
    var data: [Session]?
    var has_more: Bool?
    var next_cursor: String?

    struct Session: Decodable {
      var id: String?
      var title: String?
      var status: String?
      var worker_status: String?
      /// "bridge" for a session a computer runs under Remote Control.
      var environment_kind: String?
      /// "disconnected" once that computer has gone away.
      var connection_status: String?
      var last_event_at: String?
      var updated_at: String?
    }
  }

  private static let timestamp: ISO8601DateFormatter = {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return format
  }()
  private static let wholeSeconds = ISO8601DateFormatter()

  private static func date(_ session: Page.Session) -> Date? {
    (session.last_event_at ?? session.updated_at).flatMap { timestamp.date(from: $0) ?? wholeSeconds.date(from: $0) }
  }

  private static func remote(_ session: Page.Session, login: String) -> Remote? {
    guard let id = session.id.map(canonical), let worker = session.worker_status,
          ["running", "idle", "requires_action"].contains(worker),
          session.status != "archived", session.status != "failed" else { return nil }
    let bridge = session.environment_kind == "bridge"
    if bridge && session.connection_status == "disconnected" { return nil }
    let title = (session.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // Sessions the service keeps warm for later, not anyone's work.
    if title.contains("__CBU_POOLED__") || title == "__warming__" || title.hasPrefix("ditto:") { return nil }
    return Remote(id: id, title: title.isEmpty ? "Cloud session" : title, workerStatus: worker,
                  lastEvent: date(session), bridge: bridge, login: login)
  }

  /// Logs once each session of the last day that is left out, and why: the
  /// first thing to look at when a session does not show.
  private func noteSkipped(_ session: Page.Session) {
    guard let id = session.id, !skipped.contains(id), let last = Self.date(session),
          Date().timeIntervalSince(last) < 24 * 3600 else { return }
    skipped.insert(id)
    let why = "status \(session.status ?? "-"), worker \(session.worker_status ?? "-"), "
      + "environment \(session.environment_kind ?? "-"), connection \(session.connection_status ?? "-")"
    DispatchQueue.main.async { log("cloud", "left out \(id) \"\(session.title ?? "")\": \(why)") }
  }

  /// The same session is "cse_X" to this API and "session_X" to the older
  /// one, which the Claude app still uses for the session it has open.
  static func canonical(_ id: String) -> String {
    id.hasPrefix("session_") ? "cse_" + id.dropFirst("session_".count) : id
  }

  private static func fetch(_ request: URLRequest) -> Result<Page, Problem> {
    let done = DispatchSemaphore(value: 0)
    var result: Result<Page, Problem> = .failure(Problem(message: "no answer"))
    URLSession.shared.dataTask(with: request) { data, response, error in
      defer { done.signal() }
      if let error {
        result = .failure(Problem(message: "cannot reach the API: \(error.localizedDescription)", clears: false))
        return
      }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200, let data else {
        result = .failure(Problem(message: "the API answered HTTP \(status)", status: status))
        return
      }
      do {
        result = .success(try JSONDecoder().decode(Page.self, from: data))
      } catch {
        result = .failure(Problem(message: "the API's answer does not read: \(error)"))
      }
    }.resume()
    done.wait()
    return result
  }
}
