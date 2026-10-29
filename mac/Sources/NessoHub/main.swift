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

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var link: Link!
  private var hub: Hub!
  private var menu: StatusMenu!
  private var reactionsWindow: ReactionsWindow!

  func applicationDidFinishLaunching(_ notification: Notification) {
    link = Link()
    let meet = MeetContext(browser: browser, reactions: config.reactions, automations: config.automations)
    hub = Hub(link: link, contexts: [meet, IdleContext()])
    reactionsWindow = ReactionsWindow(reactions: config.reactions) { reactions in
      config.reactions = reactions
      config.save()
      meet.reactions = reactions
    }
    menu = StatusMenu(link: link, hub: hub) { [weak self] in self?.reactionsWindow.show() }
    link.onSettled = { [weak self] in
      log("hub", "running")
      self?.hub.start()
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
