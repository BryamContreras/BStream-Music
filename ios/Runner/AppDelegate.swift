import Flutter
import UIKit
import WidgetKit
import ImageIO
import CryptoKit

final class BStreamWidgetActionRelay {
  static let shared = BStreamWidgetActionRelay()
  var channel: FlutterMethodChannel?
  private var pendingAction: String?

  func accept(_ url: URL) {
    guard url.scheme == "bstreammusic", url.host == "widget" else { return }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let action = components?.queryItems?.first(where: { $0.name == "action" })?.value
    guard let action, ["toggle", "next", "previous", "repeat", "favorite"].contains(action) else { return }
    pendingAction = action
    channel?.invokeMethod("widgetAction", arguments: action) { [weak self] result in
      if result == nil, self?.pendingAction == action {
        self?.pendingAction = nil
      }
    }
  }

  func consume() -> String? {
    defer { pendingAction = nil }
    return pendingAction
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var localMediaChannel: FlutterMethodChannel?
  private let localMediaPlugin = IOSLocalMediaPlugin()
  private var fileExportChannel: FlutterMethodChannel?
  private let fileExportPlugin = IOSFileExportPlugin()
  private var screenChannel: FlutterMethodChannel?
  private var homeWidgetChannel: FlutterMethodChannel?
  private let widgetGroup = "group.com.bstream.bstreamMusic"
  private let widgetKind = "BStreamNowPlaying"

  private func widgetCoverName(_ trackId: String) -> String {
    let digest = SHA256.hash(data: Data(trackId.utf8))
    let prefix = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    return "now_playing_\(prefix).jpg"
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "bstream_music/local_audio",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.localMediaPlugin.handle(call, result: result)
    }
    localMediaChannel = channel

    let exportChannel = FlutterMethodChannel(
      name: "bstream_music/file_export",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    exportChannel.setMethodCallHandler { [weak self] call, result in
      self?.fileExportPlugin.handle(call, result: result)
    }
    fileExportChannel = exportChannel

    let displayChannel = FlutterMethodChannel(
      name: "bstream_music/screen",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    displayChannel.setMethodCallHandler { call, result in
      guard call.method == "setKeepScreenOn" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let arguments = call.arguments as? [String: Any]
      UIApplication.shared.isIdleTimerDisabled = arguments?["enabled"] as? Bool ?? false
      result(nil)
    }
    screenChannel = displayChannel

    let widgetChannel = FlutterMethodChannel(
      name: "bstream_music/home_widget",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    widgetChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "update":
        guard let data = call.arguments as? [String: Any],
              let defaults = UserDefaults(suiteName: self.widgetGroup) else {
          result(FlutterError(code: "widget_group", message: "App Group unavailable", details: nil))
          return
        }
        let trackId = data["trackId"] as? String ?? ""
        if defaults.string(forKey: "trackId") != trackId {
          defaults.set(false, forKey: "hasCover")
          if let previous = defaults.string(forKey: "coverFile"),
             let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: self.widgetGroup) {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(previous))
          }
          defaults.removeObject(forKey: "coverFile")
        }
        defaults.set(trackId, forKey: "trackId")
        defaults.set(data["title"] as? String ?? "", forKey: "title")
        defaults.set(data["artist"] as? String ?? "", forKey: "artist")
        defaults.set(data["isPlaying"] as? Bool ?? false, forKey: "playing")
        defaults.set(data["isFavorite"] as? Bool ?? false, forKey: "favorite")
        defaults.set(data["repeatMode"] as? String ?? "off", forKey: "repeatMode")
        defaults.set(data["accentColor"] as? Int ?? 0xFFF5F7F5, forKey: "accent")
        defaults.set(data["languageCode"] as? String ?? "es", forKey: "language")
        if #available(iOS 14.0, *) { WidgetCenter.shared.reloadTimelines(ofKind: self.widgetKind) }
        result(nil)
      case "updateArtwork":
        guard let data = call.arguments as? [String: Any],
              let defaults = UserDefaults(suiteName: self.widgetGroup),
              data["trackId"] as? String == defaults.string(forKey: "trackId"),
              let path = data["artworkPath"] as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: self.widgetGroup) else {
          result(nil)
          return
        }
        let coverName = self.widgetCoverName(data["trackId"] as? String ?? "")
        let destination = container.appendingPathComponent(coverName)
        DispatchQueue.global(qos: .utility).async {
          let source = URL(fileURLWithPath: path)
          let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
          if let imageSource = CGImageSourceCreateWithURL(source as CFURL, options as CFDictionary),
             let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 320,
               kCGImageSourceCreateThumbnailWithTransform: true,
             ] as CFDictionary),
             let bytes = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.84) {
            try? bytes.write(to: destination, options: .atomic)
            DispatchQueue.main.async {
              if defaults.string(forKey: "trackId") == data["trackId"] as? String {
                defaults.set(coverName, forKey: "coverFile")
                defaults.set(true, forKey: "hasCover")
                if #available(iOS 14.0, *) {
                  WidgetCenter.shared.reloadTimelines(ofKind: self.widgetKind)
                }
              }
            }
          }
        }
        result(nil)
      case "updateArtworkBytes":
        guard let data = call.arguments as? [String: Any],
              let defaults = UserDefaults(suiteName: self.widgetGroup),
              data["trackId"] as? String == defaults.string(forKey: "trackId"),
              let encoded = data["bytes"] as? FlutterStandardTypedData,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: self.widgetGroup) else {
          result(nil)
          return
        }
        let coverName = self.widgetCoverName(data["trackId"] as? String ?? "")
        let destination = container.appendingPathComponent(coverName)
        DispatchQueue.global(qos: .utility).async {
          if let image = UIImage(data: encoded.data),
             let bytes = image.jpegData(compressionQuality: 0.84) {
            try? bytes.write(to: destination, options: .atomic)
            DispatchQueue.main.async {
              if defaults.string(forKey: "trackId") == data["trackId"] as? String {
                defaults.set(coverName, forKey: "coverFile")
                defaults.set(true, forKey: "hasCover")
                if #available(iOS 14.0, *) {
                  WidgetCenter.shared.reloadTimelines(ofKind: self.widgetKind)
                }
              }
            }
          }
        }
        result(nil)
      case "consumePendingAction":
        result(BStreamWidgetActionRelay.shared.consume())
      case "registerActionHandler":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    homeWidgetChannel = widgetChannel
    BStreamWidgetActionRelay.shared.channel = widgetChannel
  }
}
