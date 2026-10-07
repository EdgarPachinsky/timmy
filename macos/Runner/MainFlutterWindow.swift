import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Compact tracker window, in the spirit of Upwork's.
    self.minSize = NSSize(width: 340, height: 480)
    self.setContentSize(NSSize(width: 380, height: 640))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
