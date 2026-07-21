import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let minimumWindowSize = NSSize(width: 960, height: 600)
    var windowFrame = self.frame
    windowFrame.size.width = max(windowFrame.size.width, minimumWindowSize.width)
    windowFrame.size.height = max(windowFrame.size.height, minimumWindowSize.height)

    self.minSize = minimumWindowSize
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
