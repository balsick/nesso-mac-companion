import Foundation

/// Google Meet in the browser: mic, camera and reactions.
///
/// Takes the screen whenever a Meet tab has a call or a lobby open, even when
/// the browser is in the background. KEY1 toggles the mic, KEY2 the camera.
///
/// Also runs the automations, Nesso or not: in a call one of them matches, it
/// searches the People panel for the person and reacts once they are in. The
/// panel only shows for a moment: Meet keeps it up to date once closed.
final class MeetContext: HubContext {
  let name = "meet"
  let priority = 100
  var onChange: (() -> Void)?

  struct State: Decodable, Equatable {
    var inCall: Bool
    var mic: Bool?
    var cam: Bool?
    var reactions: Bool
    /// The meeting code in the URL and the title Meet gives the call.
    var code: String?
    var title: String?
    /// While an automation watches the People panel: "opening", "watching",
    /// "no button" or "no panel" (it did not open).
    var watch: String?
    var seen: Bool?
  }

  private let browser: Browser
  /// Changed live from the Reactions window.
  var reactions: [String] {
    didSet { if reactions != oldValue { onChange?() } }
  }
  private var state: State?
  private var failure: Browser.Failure?
  /// The script's last exception, logged once.
  private var lastError: String?
  /// Whether the last poll came back empty while a call was on.
  private var missedPoll = false

  private let automations: [Config.Automation]
  /// The automation waiting for its person in the current call.
  private var armed: Config.Automation?
  /// Automations finished for a call, sent or given up: "code|person|day".
  private var finished = Set<String>()
  /// The last `State.watch`, to log its changes.
  private var watchStep: String?

  init(browser: Browser, reactions: [String], automations: [Config.Automation]) {
    self.browser = browser
    self.reactions = reactions
    self.automations = automations
  }

  var isActive: Bool { state != nil || failure != nil }

  func refresh() {
    var command = ["op": "state"]
    if let armed { command["watch"] = armed.joins }
    run(command, poll: true) { [weak self] result in
      guard let self else { return }
      let before = (self.state, self.failure)
      switch result {
      case .success(let json):
        if let json, json.hasPrefix("{\"error\""), json != self.lastError { log("meet", "script: \(json)") }
        self.lastError = json?.hasPrefix("{\"error\"") == true ? json : nil
        let read = json.flatMap { try? JSONDecoder().decode(State.self, from: Data($0.utf8)) }
        // Right after a reaction Meet's page can answer nothing for a moment.
        // One empty poll is not the end of the call, and the Nesso should
        // not flick to the clock for it.
        if read == nil, self.state != nil, !self.missedPoll {
          self.missedPoll = true
          return
        }
        self.missedPoll = false
        self.failure = nil
        self.state = read
      case .failure(let error):
        if error != self.failure { log("meet", "\(error)") }
        // Only failures that need the user's hand take over the screen; a
        // timeout or a page mid-reload just means "no call right now".
        switch error {
        case .javascriptDisabled, .notAuthorized: self.failure = error
        case .script: self.failure = nil
        }
        self.state = nil
      }
      self.automate(watching: command["watch"])
      if before.0 != self.state || before.1 != self.failure { self.onChange?() }
    }
  }

  func page(icons: IconStore) -> Page {
    if let failure { return failurePage(failure) }
    guard let state else { return Page(title: "Meet", rows: []) }

    var rows = [Row(h: 76, tiles: [
      toggle(id: "mic", on: state.mic, onSymbol: "mic.fill", offSymbol: "mic.slash.fill",
             onLabel: "MIC", offLabel: "MUTED", icons: icons),
      toggle(id: "cam", on: state.cam, onSymbol: "video.fill", offSymbol: "video.slash.fill",
             onLabel: "CAM", offLabel: "OFF", icons: icons),
    ])]

    if state.inCall && state.reactions && !reactions.isEmpty {
      let perRow = 3
      let rowCount = (reactions.count + perRow - 1) / perRow
      // Whatever is left under the toggles, split between the reaction rows.
      let free = Wire.screenHeight - 20 - 14 - 4 - 80 - 4 * rowCount
      let h = min(48, free / rowCount)
      let size = min(32, h - 10)
      for start in stride(from: 0, to: reactions.count, by: perRow) {
        let tiles = reactions[start..<min(start + perRow, reactions.count)].map { emoji in
          Tile(id: "r:\(emoji)", icon: icons.emoji(emoji, size: size, bg: Palette.tile), bg: Palette.tile)
        }
        rows.append(Row(h: h, tiles: Array(tiles)))
      }
    }

    return Page(title: "Meet", sub: state.inCall ? "in call" : "lobby", accent: "#00BFA5", rows: rows)
  }

  func handleTap(_ id: String) {
    if id == "mic" || id == "cam" {
      act(["op": id])
    } else if id.hasPrefix("r:") {
      react(String(id.dropFirst(2)), attemptsLeft: MeetScript.reactAttempts)
    }
  }

  func handleKey(_ key: Int, action: String) {
    guard action == "click", state != nil else { return }
    act(["op": key == 1 ? "mic" : "cam"])
  }

  // MARK: Actions

  private func act(_ command: [String: String]) {
    run(command) { [weak self] _ in
      // Meet updates the button a moment after the click.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.refresh() }
    }
  }

  /// Sending a reaction can take a few round trips: open the reaction bar,
  /// then Meet's full picker, then search it. Each step needs Meet to render
  /// before the next, so the script does one step and asks to be called again.
  private func react(_ emoji: String, attemptsLeft: Int, completion: ((Bool) -> Void)? = nil) {
    run(MeetScript.reactCommand(emoji)) { [weak self] result in
      guard case .success(let json?) = result else {
        log("meet", "could not send \(emoji): \(result)")
        completion?(false)
        return
      }
      if json.contains("\"retry\":true"), attemptsLeft > 1 {
        DispatchQueue.main.asyncAfter(deadline: .now() + MeetScript.reactStepDelay) {
          self?.react(emoji, attemptsLeft: attemptsLeft - 1, completion: completion)
        }
      } else {
        let ok = json.contains("\"ok\":true")
        if !ok { log("meet", "could not send \(emoji): \(json)") }
        completion?(ok)
      }
    }
  }

  // MARK: Automations

  /// Runs after every poll, `watching` being the person that poll looked
  /// for. Arms the automation that matches the call, so the next polls watch
  /// the People panel, and reacts once its person is in.
  private func automate(watching: String?) {
    guard let state, state.inCall, let code = state.code else {
      armed = nil
      return
    }
    if let rule = armed, !rule.matches(code: code, title: state.title) { armed = nil }
    guard let rule = armed, rule.joins == watching else {
      if armed == nil, let rule = automations.first(where: {
        $0.matches(code: code, title: state.title) && !finished.contains(key(rule: $0, code: code))
      }) {
        armed = rule
        log("auto", "\(state.title ?? code): watching the People panel for \(rule.joins)")
      }
      return
    }

    if state.watch != watchStep {
      watchStep = state.watch
      log("auto", "People panel: \(state.watch ?? "-")")
    }
    if state.seen == true {
      finish(rule, code: code, "\(rule.joins) is in the call, sending \(rule.react)")
      react(rule.react, attemptsLeft: MeetScript.reactAttempts) { [weak self] ok in
        if ok { log("auto", "sent \(rule.react)") }
        self?.unwatch()
      }
    } else if state.watch == "no button" || state.watch == "no panel" {
      finish(rule, code: code, "cannot watch for \(rule.joins): \(state.watch ?? "")")
      unwatch()
    }
  }

  /// Empties the People search, and closes the panel if it is still open
  /// because of us. Right after a reaction Meet's page can answer nothing
  /// for a moment, so it tries again.
  private func unwatch(attemptsLeft: Int = 5) {
    run(["op": "unwatch"]) { [weak self] result in
      if case .success(nil) = result, attemptsLeft > 1 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.unwatch(attemptsLeft: attemptsLeft - 1) }
      }
    }
  }

  private func finish(_ rule: Config.Automation, code: String, _ message: String) {
    finished.insert(key(rule: rule, code: code))
    armed = nil
    watchStep = nil
    log("auto", message)
  }

  /// Once per meeting: leaving and joining again the same day is the same
  /// meeting.
  private func key(rule: Config.Automation, code: String) -> String {
    "\(code)|\(rule.joins)|\(Date().formatted(.iso8601.year().month().day()))"
  }

  private func run(_ command: [String: String], poll: Bool = false,
                   completion: @escaping (Result<String?, Browser.Failure>) -> Void) {
    browser.run(MeetScript.with(command), inTabsMatching: "meet.google.com/", skipIfBusy: poll,
                completion: completion)
  }

  // MARK: Page pieces

  private func toggle(id: String, on: Bool?, onSymbol: String, offSymbol: String, onLabel: String,
                      offLabel: String, icons: IconStore) -> Tile {
    guard let on else { return Tile(id: id, label: "?", bg: Palette.unknown, font: "l") }
    return Tile(id: id, label: on ? onLabel : offLabel, icon: icons.symbol(on ? onSymbol : offSymbol, size: 34),
                bg: on ? Palette.on : Palette.off, fg: Palette.text, font: "s")
  }

  private func failurePage(_ failure: Browser.Failure) -> Page {
    let lines: [String]
    switch failure {
    case .javascriptDisabled: lines = ["Chrome:", "View > Developer >", "Allow JavaScript", "from Apple Events"]
    case .notAuthorized: lines = ["Allow nesso-hub", "in Privacy >", "Automation"]
    case .script: lines = ["Script error,", "see the log"]
    }
    return Page(title: "Meet", sub: "needs setup", accent: "#FFB300",
                rows: lines.map { Row(h: 24, tiles: [Tile(label: $0, bg: "#000000", font: "s")]) })
  }
}

/// Runs inside the Meet tab. Meet's class names are obfuscated and change, so
/// everything is found through aria-labels and data-is-muted, in English and
/// Italian. `__CMD__` is replaced with the command object.
enum MeetScript {
  /// Bar, picker, two searches with their looks, and the click.
  static let reactAttempts = 12
  static let reactStepDelay = 0.3

  /// `dry` finds the emoji's button without pressing it, for testing in a
  /// call without sending anything.
  static func reactCommand(_ emoji: String, dry: Bool = false) -> [String: String] {
    var command = ["op": "react", "emoji": emoji,
                   "queries": EmojiCatalog.searchTerms(for: emoji).joined(separator: "\n")]
    if dry { command["dry"] = "1" }
    return command
  }

  static func with(_ command: [String: String]) -> String {
    source.replacingOccurrences(of: "__CMD__", with: Wire.encode(command))
  }

  static let source = #"""
    (function (cmd) {
      // An exception would reach AppleScript as a bare "missing value".
      try {
        return meet(cmd);
      } catch (e) {
        return JSON.stringify({ error: String(e && e.stack || e) });
      }

      function meet(cmd) {
        function label(el) { return (el.getAttribute('aria-label') || '').toLowerCase(); }
        function strip(s) { return (s || '').replace(/\uFE0F/g, '').trim(); }
        var buttons = Array.prototype.slice.call(document.querySelectorAll('button, [role="button"]'));
        function toggle(re) {
          for (var i = 0; i < buttons.length; i++) {
            var b = buttons[i];
            if (b.hasAttribute('data-is-muted') && re.test(label(b))) return b;
          }
          return null;
        }
        function first(re) {
          for (var i = 0; i < buttons.length; i++) if (re.test(label(buttons[i]))) return buttons[i];
          return null;
        }
        var mic = toggle(/microphone|microfono/);
        var cam = toggle(/camera|fotocamera|videocamera/);
        var leave = first(/leave call|abbandona|lascia la chiamata|esci dalla chiamata/);
        var reactionBar = first(/reaction|reazion/);

        if (cmd.op === 'probe' && (mic || cam)) {
          return JSON.stringify({
            url: location.href,
            buttons: buttons.map(function (b) {
              return { label: b.getAttribute('aria-label'), text: strip(b.textContent).slice(0, 20),
                       muted: b.getAttribute('data-is-muted'), pressed: b.getAttribute('aria-pressed') };
            }).filter(function (b) { return b.label || b.text; })
          });
        }

        if (!mic && !cam) return 'null';
        function live(b) { return b ? b.getAttribute('data-is-muted') !== 'true' : null; }
        var state = { inCall: !!leave, mic: live(mic), cam: live(cam), reactions: !!reactionBar };
        var code = (location.pathname.match(/[a-z]{3}-[a-z]{4}-[a-z]{3}/) || [])[0] || null;
        var titled = document.querySelector('[data-meeting-title]');
        state.code = code;
        state.title = titled ? titled.getAttribute('data-meeting-title')
                             : document.title.replace(/^Meet\s*[-:\u2013\u2014]\s*/, '');

        // Automations look for someone in the People panel. Its search keeps
        // the list short, whether or not Meet has drawn everyone in it.
        function norm(s) {
          return (s || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/\s+/g, ' ').trim();
        }
        function type(input, text) {
          var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          setter.call(input, text);
          input.dispatchEvent(new Event('input', { bubbles: true }));
        }
        // The People button names itself through a hidden span.
        function named(el) {
          var by = el.getAttribute('aria-labelledby');
          var span = by && document.getElementById(by);
          return label(el) || (span ? span.textContent.toLowerCase() : '');
        }
        var people = null;
        for (var i = 0; i < buttons.length && !people; i++) {
          if (/^(people|persone)\b|show everyone|mostra tutti/.test(named(buttons[i]))) people = buttons[i];
        }
        var search = null;
        var inputs = document.querySelectorAll('input');
        for (var i = 0; i < inputs.length; i++) {
          var hint = label(inputs[i]) + ' ' + (inputs[i].getAttribute('placeholder') || '').toLowerCase();
          if (/search for people|cerca persone|cerca tra le persone/.test(hint)) search = inputs[i];
        }
        // A closed panel stays in the page out of sight, and so does its list:
        // Meet keeps it up to date and the search still filters it. So the
        // panel only has to open once, for Meet to draw it, and close again.
        function visible(el) { return !!el && el.getBoundingClientRect().width > 0; }
        function closePanel() {
          var panel = search && search.closest('aside');
          var closers = panel ? panel.querySelectorAll('[aria-label="Close"], [aria-label="Chiudi"]') : [];
          for (var i = 0; i < closers.length; i++) if (visible(closers[i])) return closers[i].click();
          if (people) people.click();
        }
        // The panel also lists who was invited and is not in: only the
        // participants' list counts.
        var list = null;
        var lists = document.querySelectorAll('[role="list"]');
        for (var i = 0; i < lists.length && !list; i++) {
          if (/^(participants|partecipanti)$/.test(label(lists[i]))) list = lists[i];
        }
        var open = visible(search);
        // Holds the call's code from opening the panel to closing it again.
        var root = document.documentElement;
        var ours = !!code && root.getAttribute('data-nesso-people') === code;
        if (cmd.watch && leave) {
          if (!search || !list) {
            if (open) {
              state.watch = 'opening';
            } else if (ours) {
              state.watch = 'no panel';
            } else if (people) {
              people.click();
              root.setAttribute('data-nesso-people', code);
              state.watch = 'opening';
            } else {
              state.watch = 'no button';
            }
          } else {
            if (ours) {
              if (open) closePanel();
              root.removeAttribute('data-nesso-people');
            }
            if (search.value !== cmd.watch) type(search, cmd.watch);
            var who = norm(cmd.watch);
            var found = Array.prototype.slice.call(document.querySelectorAll('[data-participant-id]'))
              .concat(Array.prototype.slice.call(list.querySelectorAll('[role="listitem"]')));
            state.seen = false;
            for (var i = 0; i < found.length && !state.seen; i++) {
              state.seen = norm(found[i].getAttribute('aria-label')).indexOf(who) >= 0 ||
                           norm(found[i].innerText).indexOf(who) >= 0;
            }
            state.watch = 'watching';
          }
        }
        if (cmd.op === 'unwatch') {
          if (search && search.value) type(search, '');
          if (ours && open) closePanel();
          root.removeAttribute('data-nesso-people');
        }

        if (cmd.op === 'mic' && mic) mic.click();
        if (cmd.op === 'cam' && cam) cam.click();
        if (cmd.op === 'react') {
          var want = strip(cmd.emoji);
          var all = document.querySelectorAll('button[data-emoji], button[aria-label], [role="button"][aria-label]');
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            if (strip(el.getAttribute('data-emoji') || el.getAttribute('aria-label')) === want) {
              var box = el.closest('[role="dialog"]');
              var search = box && box.querySelector('input[type="text"]');
              if (search && search.value) state.query = search.value;
              if (!cmd.dry) el.click();
              state.ok = true;
              state.via = el.getAttribute('role') === 'menuitem' ? 'picker' : 'bar';
              return JSON.stringify(state);
            }
          }
          var menu = document.querySelector('[role="dialog"] [role="menu"]');
          var picker = menu && menu.closest('[role="dialog"]');
          if (!picker) {
            var more = first(/more emojis|altre emoji|più emoji/);
            if (more) more.click();
            else if (reactionBar) reactionBar.click();
            state.retry = !!(more || reactionBar);
            state.step = more ? 'open picker' : 'open bar';
            return JSON.stringify(state);
          }
          var input = picker.querySelector('input[type="text"]');
          var queries = (cmd.queries || '').split('\n').filter(function (q) { return q; });
          var at = input ? queries.indexOf(input.value) : queries.length;
          // Meet updates the results a moment after the search changes; give
          // each search a few looks before trying the next one.
          var looks = input ? Number(input.getAttribute('data-nesso-looks') || 0) : 0;
          if (at >= 0 && at < queries.length && looks < 3) {
            input.setAttribute('data-nesso-looks', String(looks + 1));
            state.retry = true;
            state.step = 'wait ' + queries[at];
          } else if (at + 1 < queries.length) {
            var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            setter.call(input, queries[at + 1]);
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.setAttribute('data-nesso-looks', '0');
            state.retry = true;
            state.step = 'search ' + queries[at + 1];
          } else {
            state.notFound = true;
          }
        }
        return JSON.stringify(state);
      }
    })(__CMD__)
    """#
}
