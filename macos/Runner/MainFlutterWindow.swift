import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var windowChannel: FlutterMethodChannel?

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
    IncomingCsvFileBridge.shared.attach(messenger: flutterViewController.engine.binaryMessenger)
    let channel = FlutterMethodChannel(
      name: "bstream/desktop_window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "toggleFullScreen" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.toggleFullScreen(nil)
      result(nil)
    }
    windowChannel = channel

    super.awakeFromNib()
  }
}
