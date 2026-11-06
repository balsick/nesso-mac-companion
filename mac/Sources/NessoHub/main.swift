import AppKit
import Foundation
import SwiftUI

var config = Config.load()
let browser = Browser(bundleID: config.browser)

// `nesso-hub meet-probe` dumps what the Meet script sees in the open call:
// the first thing to look at when Meet changes its page and a button stops
// responding.
//
// `nesso-hub meet-js file.js` runs a script of your own in the Meet tab and
// prints its result, for finding your way around a Meet page that changed.
//
// Both need the Automation permission, which belongs to Nesso Hub.app, so run
// them through it: open -n -W "/Applications/Nesso Hub.app" --stdout out.txt --args meet-probe
let command = CommandLine.arguments.dropFirst().first
if command == "meet-probe" || command == "meet-js" {
  var js = MeetScript.with(["op": "probe"])
  if command == "meet-js" {
    guard CommandLine.arguments.count > 2, let source = try? String(contentsOfFile: CommandLine.arguments[2]) else {
      print("usage: nesso-hub meet-js <file.js>")
      exit(1)
    }
    js = source
  }
  switch browser.runNow(js, inTabsMatching: "meet.google.com/") {
  case .success(let json?): print(json)
  case .success(nil): print("no Meet tab open in \(config.browser)")
  case .failure(let error): print("failed: \(error)")
  }
  exit(0)
}

// `nesso-hub render-reactions out.png` draws the Reactions window into a PNG,
// to check its layout without opening it.
if CommandLine.arguments.dropFirst().first == "render-reactions", CommandLine.arguments.count > 2 {
  MainActor.assumeIsolated {
    let model = ReactionsModel(selected: config.reactions) { _ in }
    if CommandLine.arguments.count > 3 { model.query = CommandLine.arguments[3] }
    let renderer = ImageRenderer(content: ReactionsView(model: model, snapshot: true).background(Color(nsColor: .windowBackgroundColor)))
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
      try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
      print("wrote \(CommandLine.arguments[2])")
    }
  }
  exit(0)
}

// `nesso-hub render-sessions out.png [--compact]` draws the sessions window
// into a PNG, with the sessions of this Mac: the cloud's would need the
// keychain.
if command == "render-sessions", CommandLine.arguments.count > 2 {
  MainActor.assumeIsolated {
    let sessions = ClaudeSessions(cloud: false)
    sessions.refresh()
    let compact = CommandLine.arguments.contains("--compact")
    let renderer = ImageRenderer(content: SessionsView(sessions: sessions.sessions, now: Date(), compact: compact)
      .background(Color(nsColor: .windowBackgroundColor)))
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
      try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
      print("wrote \(CommandLine.arguments[2])")
    }
  }
  exit(0)
}

// `nesso-hub meet-react 🦄 [--dry]` walks through sending a reaction step by
// step, printing each one; with --dry it stops before the final click, so
// nothing reaches the call.
if command == "meet-react", CommandLine.arguments.count > 2 {
  let emoji = CommandLine.arguments[2]
  let dry = CommandLine.arguments.contains("--dry")
  print("search terms: \(EmojiCatalog.searchTerms(for: emoji))")
  for _ in 0..<MeetScript.reactAttempts {
    let result = browser.runNow(MeetScript.with(MeetScript.reactCommand(emoji, dry: dry)),
                                inTabsMatching: "meet.google.com/")
    guard case .success(let json?) = result else {
      print("failed: \(result)")
      exit(1)
    }
    print(json)
    if !json.contains("\"retry\":true") { exit(json.contains("\"ok\":true") ? 0 : 1) }
    Thread.sleep(forTimeInterval: MeetScript.reactStepDelay)
  }
  exit(1)
}

// `nesso-hub meet-watch "Name" [seconds]` looks for Name in the People panel
// of the open call the way an automation does, without reacting, and prints
// each look until Name is in or the seconds (120 by default) pass.
if command == "meet-watch", CommandLine.arguments.count > 2 {
  let name = CommandLine.arguments[2]
  let seconds = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 120 : 120
  for _ in 0..<seconds {
    let result = browser.runNow(MeetScript.with(["op": "state", "watch": name]), inTabsMatching: "meet.google.com/")
    guard case .success(let json?) = result else {
      print("failed: \(result)")
      exit(1)
    }
    print(json)
    if json.contains("\"seen\":true") { break }
    Thread.sleep(forTimeInterval: 1)
  }
  _ = browser.runNow(MeetScript.with(["op": "unwatch"]), inTabsMatching: "meet.google.com/")
  exit(0)
}

// `nesso-hub claude-probe [seconds]` prints the Claude sessions as the Claude
// page sees them, each time they change, for the seconds given (just once
// without). It runs straight from the binary: the files need no permission,
// and for the cloud sessions macOS asks once whether it may use Claude Code's
// token.
if command == "claude-probe" {
  let seconds = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 0 : 0
  let sessions = ClaudeSessions(cloud: config.claude.cloud)
  var last: ([ClaudeSessions.Session], [ClaudeCloud.Remote])?
  // The cloud's first answer comes back on the main thread, so wait for it
  // with the run loop going.
  sessions.refresh()
  RunLoop.main.run(until: Date().addingTimeInterval(sessions.cloud == nil ? 0 : 3))
  for second in 0...seconds {
    if second > 0 { RunLoop.main.run(until: Date().addingTimeInterval(1)) }
    sessions.refresh()
    let now = (sessions.sessions, sessions.cloud?.sessions ?? [])
    if let last, last == now { continue }
    last = now
    print("--- \(Date().formatted(.dateTime.hour().minute().second()))")
    if let problem = sessions.cloud?.problem { print("cloud: \(problem)") }
    for remote in sessions.cloud?.sessions ?? [] {
      let last = remote.lastEvent?.formatted(.dateTime.day().month().hour().minute()) ?? "?"
      print("cloud lists \(remote.workerStatus)\(remote.bridge ? " (remote control)" : ""): \(remote.title) [\(remote.id)] last event \(last)")
    }
    if sessions.sessions.isEmpty { print("(nothing to show)") }
    for session in sessions.sessions {
      let wait = session.waitingFor.map { " (\($0))" } ?? ""
      let pid = session.pid.map { " pid \($0)" } ?? ""
      print("\(session.state)\(wait): \(session.name) [\(session.key)\(pid)] since \(session.since.formatted(.dateTime.hour().minute()))")
    }
  }
  exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var link: Link!
  private var hub: Hub!
  private var menu: StatusMenu!
  private var reactionsWindow: ReactionsWindow!
  private var sessionsWindow: SessionsWindow!

  func applicationDidFinishLaunching(_ notification: Notification) {
    link = Link()
    let meet = MeetContext(browser: browser, reactions: config.reactions, automations: config.automations)
    let claude = ClaudeContext(config: config.claude)
    hub = Hub(link: link, contexts: [meet, claude, IdleContext()], indicator: claude)
    reactionsWindow = ReactionsWindow(reactions: config.reactions) { reactions in
      config.reactions = reactions
      config.save()
      meet.reactions = reactions
    }
    sessionsWindow = SessionsWindow(claude: claude, compact: config.claude.compact, onVisibilityChange: { visible in
      guard config.claude.window != visible else { return }
      config.claude.window = visible
      config.save()
    }, onCompactChange: { compact in
      config.claude.compact = compact
      config.save()
    })
    menu = StatusMenu(link: link, hub: hub, claude: claude, sessionsWindow: sessionsWindow) { [weak self] in
      self?.reactionsWindow.show()
    }
    link.onSettled = { [weak self] in
      log("hub", "running")
      self?.hub.start()
      if config.claude.window { self?.sessionsWindow.show() }
    }
    // A menu bar app is never frontmost on its own, and macOS shows the
    // permission prompts of an app that is not frontmost behind everything.
    NSApp.activate(ignoringOtherApps: true)
    log("hub", "waiting for the Bluetooth permission")
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only: no Dock icon, no app menu. Matches LSUIElement in Info.plist.
app.setActivationPolicy(.accessory)
app.run()
