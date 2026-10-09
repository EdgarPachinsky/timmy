import Cocoa
import FlutterMacOS

/// Timmy in the macOS menu bar: a "t" in a circle, or, while a timer exists,
/// a pill with "t", the task (its Jira key when it has one) and the time.
/// A filled pill means running, an outlined one paused.
///
/// Flutter sends the state over the `timmy/menu_bar` channel whenever it
/// changes; the clock ticks here, from the elapsed time it was sent, so
/// Flutter doesn't have to send it every second. Menu clicks go back to
/// Flutter as `action` calls.
final class StatusItemController: NSObject, NSMenuDelegate {
  static let shared = StatusItemController()

  private var statusItem: NSStatusItem?
  private var channel: FlutterMethodChannel?
  private weak var window: NSWindow?
  private var ticker: Timer?
  private var lastText: String?

  /// The last state from Flutter (see `lib/core/status_bar.dart`), and when
  /// it arrived, to count the running timer on from there.
  private var state: [String: Any] = [:]
  private var receivedAt = Date()

  private var timer: [String: Any]? { state["timer"] as? [String: Any] }
  private var isRunning: Bool { (timer?["running"] as? Bool) ?? false }

  func attach(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.window = window
    let channel = FlutterMethodChannel(name: "timmy/menu_bar", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "update":
        self.state = call.arguments as? [String: Any] ?? [:]
        self.receivedAt = Date()
        self.refresh()
        result(nil)
      case "show":
        self.showTimmy()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    item.menu = menu
    statusItem = item
    refresh()
  }

  // MARK: - Icon

  private func refresh() {
    lastText = nil
    redraw()
    if isRunning {
      if ticker == nil {
        // Twice a second so the seconds never skip; redrawn only on change.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.redraw() }
        // .common keeps it ticking while the menu is open.
        RunLoop.main.add(t, forMode: .common)
        ticker = t
      }
    } else {
      ticker?.invalidate()
      ticker = nil
    }
  }

  private func redraw() {
    guard let button = statusItem?.button else { return }
    guard let timer = timer else {
      if lastText != "" {
        lastText = ""
        button.image = Self.circleImage()
        button.toolTip = "Timmy"
      }
      return
    }
    let label = timer["label"] as? String ?? ""
    let text = [label, Self.clock(elapsedSeconds)].filter { !$0.isEmpty }.joined(separator: "  ")
    let key = "\(isRunning)|\(text)"
    if key == lastText { return }
    lastText = key
    button.image = Self.pillImage(text: text, filled: isRunning)
    let title = timer["title"] as? String ?? ""
    button.toolTip = isRunning ? title : "\(title) (paused)"
  }

  private var elapsedSeconds: Int {
    guard let timer = timer else { return 0 }
    let base = (timer["elapsedMs"] as? NSNumber)?.doubleValue ?? 0
    let extra = isRunning ? Date().timeIntervalSince(receivedAt) * 1000 : 0
    return max(0, Int((base + extra) / 1000))
  }

  /// "22:34" under an hour, "1:22:34" from then on.
  private static func clock(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
  }

  private static let letterFont = NSFont.systemFont(ofSize: 12, weight: .bold)
  private static let textFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
  private static let iconHeight: CGFloat = 18

  /// A filled circle with the "t" cut out. Template images take the menu
  /// bar's color, light or dark.
  private static func circleImage() -> NSImage {
    let side = iconHeight
    let t = NSAttributedString(string: "t", attributes: [.font: letterFont, .foregroundColor: NSColor.black])
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
      Self.knockOut {
        let size = t.size()
        t.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 0.5))
      }
      return true
    }
    image.isTemplate = true
    return image
  }

  /// A pill with "t  <text>": filled with the text cut out while running,
  /// outlined with solid text while paused.
  private static func pillImage(text: String, filled: Bool) -> NSImage {
    let attrs: (NSFont) -> [NSAttributedString.Key: Any] = { [.font: $0, .foregroundColor: NSColor.black] }
    let t = NSAttributedString(string: "t", attributes: attrs(letterFont))
    let body = NSAttributedString(string: text, attributes: attrs(textFont))
    let height = iconHeight, pad: CGFloat = 7, gap: CGFloat = 5
    let width = ceil(pad + t.size().width + gap + body.size().width + pad)
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
      let radius = height / 2 - 0.5
      let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
      NSColor.black.set()
      if filled {
        pill.fill()
      } else {
        pill.lineWidth = 1
        pill.stroke()
      }
      let drawText = {
        t.draw(at: NSPoint(x: pad, y: (height - t.size().height) / 2 + 0.5))
        body.draw(at: NSPoint(x: pad + t.size().width + gap, y: (height - body.size().height) / 2))
      }
      if filled { Self.knockOut(drawText) } else { drawText() }
      return true
    }
    image.isTemplate = true
    return image
  }

  /// Runs [draw] erasing what's under it instead of painting.
  private static func knockOut(_ draw: () -> Void) {
    guard let context = NSGraphicsContext.current else { return draw() }
    context.saveGraphicsState()
    context.cgContext.setBlendMode(.destinationOut)
    draw()
    context.restoreGraphicsState()
  }

  // MARK: - Menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    if let timer = timer {
      let title = timer["title"] as? String ?? ""
      menu.addItem(info(title.isEmpty ? "Untitled task" : title, bold: true))
      let project = timer["project"] as? String ?? ""
      let detail = [project, Self.clock(elapsedSeconds), isRunning ? "" : "Paused"]
        .filter { !$0.isEmpty }.joined(separator: " · ")
      menu.addItem(info(detail))
      menu.addItem(action(isRunning ? "Pause" : "Resume", id: isRunning ? "pause" : "resume"))
      let end = NSMenuItem(title: "End", action: nil, keyEquivalent: "")
      let endMenu = NSMenu()
      endMenu.autoenablesItems = false
      endMenu.addItem(action("Save to Time-Wise", id: "end_upload"))
      endMenu.addItem(action("Keep on this Mac", id: "end_local"))
      end.submenu = endMenu
      menu.addItem(end)
      menu.addItem(.separator())
    } else if state["signedIn"] as? Bool == true {
      menu.addItem(info("No timer running"))
      menu.addItem(.separator())
    }

    if let today = state["today"] as? String {
      menu.addItem(info(today))
      menu.addItem(.separator())
    }

    if let plan = state["plan"] as? [[String: Any]] {
      menu.addItem(info("Today's plan", bold: true))
      if plan.isEmpty {
        menu.addItem(info("Nothing planned"))
      }
      for (i, step) in plan.enumerated() {
        let title = step["title"] as? String ?? ""
        let minutes = step["detail"] as? String ?? ""
        let item = action(minutes.isEmpty ? title : "\(title)  ·  \(minutes)", id: "plan:\(i)")
        // Starting another task needs the current timer ended first.
        item.isEnabled = timer == nil
        item.toolTip = timer == nil ? "Start tracking this task" : "End the running timer first"
        menu.addItem(item)
      }
      menu.addItem(.separator())
    }

    if let standup = state["standup"] as? [String: Any], let text = standup["text"] as? String {
      let when = standup["when"] as? String ?? ""
      let item = NSMenuItem(title: when.isEmpty ? "Last standup" : "Last standup · \(when)", action: nil, keyEquivalent: "")
      let sub = NSMenu()
      sub.autoenablesItems = false
      for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
        let s = String(line)
        sub.addItem(info(s.count > 90 ? String(s.prefix(89)) + "…" : (s.isEmpty ? " " : s)))
      }
      sub.addItem(.separator())
      let copy = NSMenuItem(title: "Copy standup", action: #selector(copyStandup), keyEquivalent: "")
      copy.target = self
      sub.addItem(copy)
      item.submenu = sub
      menu.addItem(item)
      menu.addItem(.separator())
    }

    let show = NSMenuItem(title: "Show Timmy", action: #selector(showTimmy), keyEquivalent: "")
    show.target = self
    menu.addItem(show)
    let quit = NSMenuItem(title: "Quit Timmy", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
  }

  /// A greyed-out line of information.
  private func info(_ title: String, bold: Bool = false) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    if bold {
      item.attributedTitle = NSAttributedString(
        string: title,
        attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
    }
    return item
  }

  /// An item whose click is handled in Flutter.
  private func action(_ title: String, id: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(sendAction(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = id
    item.isEnabled = true
    return item
  }

  @objc private func sendAction(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    channel?.invokeMethod("action", arguments: id)
  }

  @objc private func copyStandup() {
    guard let standup = state["standup"] as? [String: Any], let text = standup["text"] as? String else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  @objc private func showTimmy() {
    NSApp.activate(ignoringOtherApps: true)
    guard let window = window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
