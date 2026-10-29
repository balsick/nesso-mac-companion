import AppKit

/// The menu bar icon: whether the Nesso is connected, which context owns its
/// screen, and the way out.
final class StatusMenu: NSObject, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let link: Link
  private let hub: Hub
  private let showReactions: () -> Void

  init(link: Link, hub: Hub, showReactions: @escaping () -> Void) {
    self.link = link
    self.hub = hub
    self.showReactions = showReactions
    super.init()
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    link.onStatus = { [weak self] in self?.updateIcon() }
    updateIcon()
  }

  private func updateIcon() {
    let image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Nesso Hub")
    image?.isTemplate = true
    item.button?.image = image
    // Dimmed until the Nesso is actually connected.
    item.button?.appearsDisabled = !link.isReady
    item.button?.toolTip = "Nesso Hub: \(link.status)"
  }

  // Rebuilt on every open, so it never shows stale state.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(disabled("Nesso: \(link.status)"))
    menu.addItem(disabled("Screen: \(hub.contextName)"))
    menu.addItem(.separator())
    menu.addItem(action("Choose Reactions…", #selector(chooseReactions), key: ","))
    menu.addItem(action("Open Config File", #selector(openConfig), key: ""))
    menu.addItem(action("Show Log", #selector(openLog), key: "l"))
    menu.addItem(.separator())
    menu.addItem(action("Quit Nesso Hub", #selector(quit), key: "q"))
  }

  private func disabled(_ title: String) -> NSMenuItem {
    let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    entry.isEnabled = false
    return entry
  }

  private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
    let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
    entry.target = self
    return entry
  }

  @objc private func chooseReactions() { showReactions() }

  @objc private func openConfig() { NSWorkspace.shared.open(Config.url) }

  @objc private func openLog() { NSWorkspace.shared.open(logURL) }

  @objc private func quit() { NSApp.terminate(nil) }
}
