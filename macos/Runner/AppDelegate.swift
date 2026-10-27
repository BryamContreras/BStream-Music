import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { IncomingCsvFileBridge.shared.accept(url) }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
