import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var localMediaChannel: FlutterMethodChannel?
  private let localMediaPlugin = IOSLocalMediaPlugin()
  private var fileExportChannel: FlutterMethodChannel?
  private let fileExportPlugin = IOSFileExportPlugin()
  private var screenChannel: FlutterMethodChannel?

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
  }
}
