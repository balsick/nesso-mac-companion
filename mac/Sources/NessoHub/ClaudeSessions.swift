import AppKit
import Darwin
import Foundation

/// The Claude Code sessions on this Mac, read from the files Claude Code and
/// the Claude app keep for themselves:
///
/// - `~/.claude/sessions/<pid>.json`, one per running `claude` process, from
///   a terminal or from the Claude app's Code tab: `status` is "busy",
///   "waiting" (a permission prompt or a question) or "idle".
/// - `~/Library/Application Support/Claude/claude-code-sessions/*/*/local_<id>.json`,
///   the Claude app's record of each of its sessions: the title, whether it
///   is archived, when it was last opened and when it last did something.
/// - ClaudeCloud, for the sessions that run in the cloud or on another
///   computer under Remote Control.
///
/// Neither format is documented, so every field is optional and a file that
/// does not read is skipped.
final class ClaudeSessions {
  struct Session: Equatable {
    /// In order of urgency.
    enum State: Int, Comparable {
      /// Stopped on a permission prompt or a question.
      case waiting
      /// Finished while you were looking elsewhere.
      case done
      case working
      /// Open, with nothing new since you last looked.
      case idle

      static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    }

    /// The Claude app's "local_…" id, the cloud's "session_…" one, or
    /// "pid:<pid>" for a terminal session.
    var key: String
    var name: String
    var state: State
    /// What it waits for: "permission prompt" or "input needed".
    var waitingFor: String?
    /// When it entered `state`.
    var since: Date
    /// Set for the sessions of the Claude app and of the cloud, which open by
    /// link.
    var appSession: String?
    /// The process, while it runs.
    var pid: pid_t?
    /// The Claude app instance that opens it: with two instances open, each
    /// signed in to its own organisation, a link sent to the app as a whole
    /// lands in either.
    var instance: pid_t?
  }

  /// Most urgent first: the oldest first within a state, except for idle
  /// sessions, which come most recent first.
  private(set) var sessions: [Session] = []

  static let claudeApp = "com.anthropic.claudefordesktop"

  /// A record of the Claude app whose session last did something this long
  /// ago is history, even if it was never opened since.
  private static let doneHorizon: TimeInterval = 24 * 3600
  /// An idle session left alone this long is a terminal tab nobody went back
  /// to, and is not shown.
  private static let idleHorizon: TimeInterval = 12 * 3600

  private let registryDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
  private let recordsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
  private let appConfig = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")

  /// Nil when the cloud sessions are turned off.
  let cloud: ClaudeCloud?

  init(cloud: Bool) {
    self.cloud = cloud ? ClaudeCloud() : nil
  }

  /// The Claude app's records by session id, re-read only when a file changes.
  private var records: [String: (modified: Date, record: AppRecord)] = [:]
  /// When Nesso Hub last saw a session on screen: the Claude app only stamps
  /// `lastFocusedAt` when a session is opened, not while it stays open.
  private var seenAt: [String: Double] = [:]
  /// Terminal and cloud sessions seen busy or waiting since they were last in
  /// front: once idle they are done until they come to the front.
  private var worked = Set<String>()
  /// The Claude app instance each organisation was last seen in, from the
  /// sessions it runs, and the organisation each Claude Code login lists,
  /// from the sessions of this Mac it lists under Remote Control.
  private var instances: [String: pid_t] = [:]
  private var loginOrgs: [String: String] = [:]
  private var lastProblem: String?

  func refresh() {
    let now = Date()
    let nowMs = now.timeIntervalSince1970 * 1000
    let records = readRecords()
    let front = NSWorkspace.shared.frontmostApplication
    cloud?.refresh()

    // With the Claude app in front, the session opened last is the one on
    // screen. The app notes it in its settings; failing that, it is the
    // record opened last, though that misses the cloud's.
    var onScreen: String?
    if front?.bundleIdentifier == Self.claudeApp {
      onScreen = lastOpened().map(ClaudeCloud.canonical)
        ?? records.max { ($0.value.lastFocusedAt ?? 0) < ($1.value.lastFocusedAt ?? 0) }?.key
      if let onScreen { seenAt[onScreen] = nowMs }
    }
    func unseen(_ id: String, _ record: AppRecord) -> Bool {
      guard id != onScreen, let activity = record.lastActivityAt else { return false }
      return activity > max(record.lastFocusedAt ?? 0, seenAt[id] ?? 0)
    }

    var found: [Session] = []
    var running = Set<String>()
    instances = instances.filter { Self.isClaude($0.value) }
    for registration in readRegistry() {
      guard let pid = registration.pid, registration.spare != true,
            Self.isRunning(pid, startedAt: registration.procStart) else { continue }
      let id = registration.hostSessionId
      let record = id.flatMap { records[$0] }
      if record?.isArchived == true { continue }
      let key = id ?? "pid:\(pid)"
      running.insert(key)
      let instance = Self.hostApp(of: pid).flatMap { $0.bundleIdentifier == Self.claudeApp ? $0.processIdentifier : nil }
      if let org = record?.org, let instance { instances[org] = instance }

      let since = registration.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
      let state: Session.State
      switch registration.status {
      case "waiting":
        state = .waiting
        worked.insert(key)
      case "busy":
        state = .working
        worked.insert(key)
      default:
        if let id, let record {
          state = unseen(id, record) ? .done : .idle
        } else if worked.contains(key) {
          // A terminal session is seen once its terminal is in front.
          if let host = Self.hostApp(of: pid), host == front { worked.remove(key) }
          state = worked.contains(key) ? .done : .idle
        } else {
          state = .idle
        }
        if state == .idle, now.timeIntervalSince(since) > Self.idleHorizon { continue }
      }
      let name = record?.title ?? registration.name ?? registration.cwd.map { ($0 as NSString).lastPathComponent }
      found.append(Session(key: key, name: name ?? "Claude", state: state,
                           waitingFor: state == .waiting ? registration.waitingFor : nil,
                           since: since, appSession: id, pid: pid, instance: instance))
    }

    // A session this Mac runs under Remote Control is in the list already,
    // from its process: its record knows its bridge id, and failing that it
    // goes by the same title.
    var bridged: [String: String] = [:]
    for record in records.values {
      for bridge in record.bridgeSessionIds ?? [] { bridged[ClaudeCloud.canonical(bridge)] = record.org }
    }
    var localOrgs: [String: String] = [:]
    for session in found {
      if let id = session.appSession, let org = records[id]?.org { localOrgs[session.name] = org }
    }
    let local = Set(found.map(\.name))
    for remote in cloud?.sessions ?? [] {
      if remote.bridge, let org = bridged[remote.id] ?? localOrgs[remote.title] {
        // A session of this Mac's: it tells which organisation the login is for.
        loginOrgs[remote.login] = org
        continue
      }
      if remote.bridge && local.contains(remote.title) { continue }
      let key = remote.id
      let since = remote.lastEvent ?? now
      running.insert(key)
      let state: Session.State
      switch remote.workerStatus {
      case "requires_action":
        state = .waiting
        worked.insert(key)
      case "running":
        state = .working
        worked.insert(key)
      default:
        if key == onScreen { worked.remove(key) }
        state = worked.contains(key) ? .done : .idle
        if state == .idle, now.timeIntervalSince(since) > Self.idleHorizon { continue }
      }
      found.append(Session(key: key, name: remote.title, state: state, since: since, appSession: key,
                           instance: loginOrgs[remote.login].flatMap { instances[$0] }))
    }
    worked.formIntersection(running)

    // The Claude app stops the process of a session that has been idle a
    // while, and it still counts until it is opened.
    for (id, record) in records where !running.contains(id) && record.isArchived != true {
      guard let activity = record.lastActivityAt, nowMs - activity < Self.doneHorizon * 1000,
            unseen(id, record) else { continue }
      found.append(Session(key: id, name: record.title ?? "Claude", state: .done,
                           since: Date(timeIntervalSince1970: activity / 1000), appSession: id,
                           instance: record.org.flatMap { instances[$0] }))
    }

    sessions = found.sorted { a, b in
      guard a.state == b.state else { return a.state < b.state }
      return a.state == .idle ? a.since > b.since : a.since < b.since
    }
  }

  /// Brings a session to the front: the Claude app opens its own sessions by
  /// link, and a terminal session's terminal is brought forward.
  func open(_ session: Session) {
    // The app takes its own sessions as ?session=, and cloud ones in the path.
    let link = session.appSession.map { $0.hasPrefix("local_") ? "claude://code/continue?session=\($0)" : "claude://code/\($0)" }
    if let link, let url = URL(string: link) {
      guard let instance = session.instance else {
        NSWorkspace.shared.open(url)
        return
      }
      // Sending the event can wait on macOS asking whether Nesso Hub may
      // control Claude.
      DispatchQueue.global().async {
        let sent = Self.send(url, to: instance)
        DispatchQueue.main.async {
          if sent {
            NSRunningApplication(processIdentifier: instance)?.activate()
          } else {
            NSWorkspace.shared.open(url)
          }
        }
      }
    } else if let pid = session.pid, let host = Self.hostApp(of: pid) {
      host.activate()
    } else {
      log("claude", "no way to open \(session.name)")
    }
  }

  /// Hands `url` to one instance of the Claude app, the way macOS hands it a
  /// claude:// link: a 'GURL' Apple event, sent to its process.
  private static func send(_ url: URL, to pid: pid_t) -> Bool {
    let gurl: AEEventClass = 0x4755_524C  // 'GURL'
    let directObject: AEKeyword = 0x2D2D_2D2D  // '----'
    let event = NSAppleEventDescriptor(eventClass: gurl, eventID: gurl,
                                       targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                       returnID: -1, transactionID: 0)
    event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: directObject)
    do {
      _ = try event.sendEvent(options: .noReply, timeout: 10)
      return true
    } catch {
      DispatchQueue.main.async { log("claude", "could not hand \(url) to Claude \(pid): \(error)") }
      return false
    }
  }

  private static func isClaude(_ pid: pid_t) -> Bool {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == claudeApp
  }

  // MARK: Files

  private struct Registration: Decodable {
    var pid: Int32?
    var procStart: String?
    var cwd: String?
    var name: String?
    var status: String?
    var waitingFor: String?
    var statusUpdatedAt: Double?
    var hostSessionId: String?
    /// A process started ahead of time, not yet given a session.
    var spare: Bool?
  }

  private struct AppRecord: Decodable {
    var title: String?
    var isArchived: Bool?
    /// The ids its session has on claude.ai while under Remote Control.
    var bridgeSessionIds: [String]?
    var lastFocusedAt: Double?
    var lastActivityAt: Double?
    /// The organisation whose folder it is in; not in the file.
    var org: String?
  }

  private func readRegistry() -> [Registration] {
    let files = (try? FileManager.default.contentsOfDirectory(at: registryDir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { file in
      guard let data = try? Data(contentsOf: file) else { return nil }
      do {
        return try JSONDecoder().decode(Registration.self, from: data)
      } catch {
        problem("\(file.lastPathComponent) does not read: \(error)")
        return nil
      }
    }
  }

  /// Two levels down, one folder per account and organisation.
  private func readRecords() -> [String: AppRecord] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    var current: [String: (modified: Date, record: AppRecord)] = [:]
    for account in (try? fm.contentsOfDirectory(at: recordsDir, includingPropertiesForKeys: nil)) ?? [] {
      for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
        for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: keys)) ?? [] {
          let id = file.deletingPathExtension().lastPathComponent
          guard id.hasPrefix("local_"), file.pathExtension == "json",
                let modified = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate else { continue }
          if let cached = records[id], cached.modified == modified {
            current[id] = cached
          } else if let data = try? Data(contentsOf: file),
                    var record = try? JSONDecoder().decode(AppRecord.self, from: data) {
            record.org = org.lastPathComponent
            current[id] = (modified, record)
          }
        }
      }
    }
    records = current
    return current.mapValues(\.record)
  }

  /// The Code session opened last in the Claude app, in any of its windows:
  /// preferences.epitaxyPrefs["desktop-frame.paneStore.v1"].state.lastPrimaryCodeSession.id.
  private func lastOpened() -> String? {
    guard let data = try? Data(contentsOf: appConfig),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let prefs = (json["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any],
          let state = (prefs["desktop-frame.paneStore.v1"] as? [String: Any])?["state"] as? [String: Any],
          let session = state["lastPrimaryCodeSession"] as? [String: Any] else { return nil }
    return session["id"] as? String
  }

  private func problem(_ message: String) {
    if message != lastProblem { log("claude", message) }
    lastProblem = message
  }

  // MARK: Processes

  private static let startFormat: DateFormatter = {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "UTC")
    format.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return format
  }()

  private static func process(_ pid: pid_t) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
  }

  /// Whether `pid` is still the process that wrote the file: a session that
  /// ended can leave its file behind, and its pid can go to something else.
  /// `procStart` is `ps -o lstart` in UTC: "Mon Nov  2 11:57:52 2026".
  private static func isRunning(_ pid: pid_t, startedAt procStart: String?) -> Bool {
    guard let info = process(pid) else { return false }
    guard let procStart,
          let expected = startFormat.date(from: procStart.split(separator: " ").joined(separator: " "))
    else { return true }
    let started = TimeInterval(info.kp_proc.p_un.__p_starttime.tv_sec)
    return abs(started - expected.timeIntervalSince1970) < 2
  }

  /// The app a terminal session runs in, such as Terminal or iTerm: its
  /// first ancestor that is a regular app.
  static func hostApp(of pid: pid_t) -> NSRunningApplication? {
    var current = pid
    for _ in 0..<16 {
      guard let parent = process(current)?.kp_eproc.e_ppid, parent > 1 else { return nil }
      if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular { return app }
      current = parent
    }
    return nil
  }
}
