import AppKit
import Foundation

/// Runs JavaScript in browser tabs through AppleScript, so web apps can be
/// driven without installing a browser extension.
///
/// Needs, once: View > Developer > Allow JavaScript from Apple Events in the
/// browser, and the Automation permission macOS asks for on first use.
///
/// Calls go through `osascript` on a serial background queue: an Apple Event
/// can block for minutes (the first one waits on the permission prompt), and
/// nothing else in the app may wait with it.
final class Browser {
  enum Failure: Error, Equatable {
    /// The browser refuses JavaScript from Apple Events.
    case javascriptDisabled
    /// macOS denied the Automation permission.
    case notAuthorized
    case script(String)
  }

  let bundleID: String
  private let queue = DispatchQueue(label: "nesso-hub.browser")
  private var busy = false

  init(bundleID: String) { self.bundleID = bundleID }

  /// `tell application` would launch the browser, so check first.
  var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

  /// Runs `js` in each tab whose URL contains `urlPart` and hands back, on the
  /// main queue, the first result that is not "null". Nil when no tab matched
  /// or every tab said null. With `skipIfBusy`, a call made while another is
  /// still running is dropped instead of queued: that is what polling wants.
  func run(_ js: String, inTabsMatching urlPart: String, skipIfBusy: Bool = false,
           completion: @escaping (Result<String?, Failure>) -> Void) {
    guard isRunning else {
      completion(.success(nil))
      return
    }
    if skipIfBusy && busy { return }
    busy = true
    let source = script(js, urlPart: urlPart)
    queue.async {
      let result = Self.osascript(source)
      DispatchQueue.main.async {
        self.busy = false
        completion(result)
      }
    }
  }

  /// Blocking variant, for the command line.
  func runNow(_ js: String, inTabsMatching urlPart: String) -> Result<String?, Failure> {
    guard isRunning else { return .success(nil) }
    return Self.osascript(script(js, urlPart: urlPart))
  }

  private func script(_ js: String, urlPart: String) -> String {
    """
    tell application id "\(bundleID)"
      repeat with w in windows
        repeat with t in tabs of w
          if URL of t contains "\(escape(urlPart))" then
            set r to execute t javascript "\(escape(asciiOnly(js)))"
            if r is not missing value and r is not "null" then return r
          end if
        end repeat
      end repeat
    end tell
    return ""
    """
  }

  private static func osascript(_ source: String) -> Result<String?, Failure> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
      try process.run()
    } catch {
      return .failure(.script("could not start osascript: \(error)"))
    }
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let errors = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      if message.contains("-1743") { return .failure(.notAuthorized) }
      if message.localizedCaseInsensitiveContains("JavaScript") { return .failure(.javascriptDisabled) }
      return .failure(.script(message))
    }
    let value = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return .success(value.isEmpty ? nil : value)
  }

  /// Rewrites every non-ASCII character as a JavaScript \u escape. The
  /// script reaches osascript as a process argument, and macOS converts
  /// arguments to their file system form, which decomposes accents: "ñ"
  /// arrives as "n" plus a combining tilde, and Meet's search no longer finds
  /// `:piñata:`. Plain ASCII survives untouched.
  private func asciiOnly(_ js: String) -> String {
    var out = ""
    out.reserveCapacity(js.utf16.count)
    for unit in js.utf16 {
      if unit < 0x80 {
        out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
      } else {
        out += String(format: "\\u%04x", unit)
      }
    }
    return out
  }

  private func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
  }
}
