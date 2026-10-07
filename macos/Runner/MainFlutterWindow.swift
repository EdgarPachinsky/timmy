import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    migrateSandboxPreferences()
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Fixed-size compact tracker window, in the spirit of Upwork's.
    let size = NSSize(width: 344, height: 770)
    self.styleMask.remove(.resizable)
    self.setContentSize(size)
    self.contentMinSize = size
    self.contentMaxSize = size
    self.collectionBehavior.insert(.fullScreenNone)
    self.standardWindowButton(.zoomButton)?.isEnabled = false
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// Timmy used to run in the macOS app sandbox, which keeps preferences inside
  /// its container. It now runs unsandboxed (so it can start the Claude Code
  /// CLI), which reads ~/Library/Preferences instead. Copy the old values over
  /// once, before Flutter reads them, so sign-in, timers, local entries and the
  /// Jira connection carry over.
  private func migrateSandboxPreferences() {
    guard let id = Bundle.main.bundleIdentifier else { return }
    let defaults = UserDefaults.standard
    let doneKey = "timmy.migratedFromSandbox"
    if defaults.bool(forKey: doneKey) { return }
    let old = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Containers/\(id)/Data/Library/Preferences/\(id).plist")
    if let values = NSDictionary(contentsOf: old) as? [String: Any] {
      for (key, value) in values where key.hasPrefix("flutter.") && defaults.object(forKey: key) == nil {
        defaults.set(value, forKey: key)
      }
    }
    defaults.set(true, forKey: doneKey)
  }
}
