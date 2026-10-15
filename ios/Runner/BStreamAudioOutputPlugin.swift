import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import UIKit

// Music routes are owned by iOS. Do not use availableInputs, playAndRecord,
// overrideOutputAudioPort or a Bluetooth communication route for music playback.
final class BStreamAudioOutputPlugin: NSObject {
  private let channel: FlutterMethodChannel
  private let session = AVAudioSession.sharedInstance()
  private var isWatching = false
  private var observers: [NSObjectProtocol] = []
  private var volumeObservation: NSKeyValueObservation?
  private var volumeView: MPVolumeView?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "bstream_music/audio_output", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      self.handle(call, result: result)
    }
  }

  deinit { stopWatching() }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getState":
      result(state())
    case "startWatching":
      startWatching()
      result(state())
    case "stopWatching":
      stopWatching()
      result(nil)
    case "selectRoute", "showSystemPicker":
      // Apple exposes the current route, not a list of directly selectable
      // Bluetooth outputs. Let the genuine system picker perform the transfer.
      showPicker(result: result)
    case "setVolume":
      let arguments = call.arguments as? [String: Any]
      guard let value = arguments?["volume"] as? NSNumber, value.doubleValue.isFinite else {
        result(FlutterError(code: "invalid_volume", message: "Invalid volume", details: nil))
        return
      }
      setVolume(Float(max(0, min(1, value.doubleValue))), result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func state() -> [String: Any] {
    let outputs = session.currentRoute.outputs
    let builtinSelected = outputs.isEmpty || outputs.contains {
      $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
    }
    var routes: [[String: Any]] = [[
      "id": "ios:device", "name": UIDevice.current.model, "type": "speaker",
      "selected": builtinSelected, "selectable": true,
    ]]
    for output in outputs where output.portType != .builtInSpeaker && output.portType != .builtInReceiver {
      let type: String
      switch output.portType {
      case .headphones, .lineOut: type = "wired"
      case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: type = "bluetooth"
      case .usbAudio: type = "usb"
      default: type = "other"
      }
      routes.append([
        "id": output.uid, "name": output.portName, "type": type,
        "selected": true, "selectable": true,
      ])
    }
    return [
      "supported": true, "routes": routes, "volume": Double(session.outputVolume),
      "hasSystemPicker": true,
    ]
  }

  private func emit() {
    guard isWatching, UIApplication.shared.applicationState == .active else { return }
    channel.invokeMethod("audioOutputChanged", arguments: state())
  }

  private func startWatching() {
    guard !isWatching else { emit(); return }
    isWatching = true
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                         object: session, queue: .main) { [weak self] _ in self?.emit() })
    observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                         object: nil, queue: .main) { [weak self] _ in self?.emit() })
    volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.emit() }
    }
    emit()
  }

  private func stopWatching() {
    isWatching = false
    volumeObservation?.invalidate()
    volumeObservation = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    volumeView?.removeFromSuperview()
    volumeView = nil
  }

  private func showPicker(result: @escaping FlutterResult) {
    guard UIApplication.shared.applicationState == .active,
          let presenter = bstreamAudioPresentationController(),
          !presenter.isBeingDismissed, !presenter.isBeingPresented,
          !(presenter is BStreamSystemAudioPickerController) else {
      result(FlutterError(code: "output_picker_unavailable", message: "Audio picker unavailable", details: nil))
      return
    }
    let picker = BStreamSystemAudioPickerController()
    presenter.present(picker, animated: true) { result(true) }
  }

  private func setVolume(_ value: Float, result: @escaping FlutterResult) {
    guard UIApplication.shared.applicationState == .active,
          let presenter = bstreamAudioPresentationController() else {
      result(FlutterError(code: "volume_unavailable", message: "Open the app to change volume", details: nil))
      return
    }
    if volumeView == nil || volumeView?.superview == nil {
      let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 300, height: 44))
      view.showsRouteButton = false
      presenter.view.addSubview(view)
      volumeView = view
    }
    // MPVolumeView creates its system slider after entering a view hierarchy.
    DispatchQueue.main.async { [weak self] in
      guard let self, let slider = self.volumeView?.subviews.compactMap({ $0 as? UISlider }).first else {
        result(FlutterError(code: "volume_unavailable", message: "System volume is unavailable", details: nil))
        return
      }
      slider.setValue(value, animated: false)
      slider.sendActions(for: .valueChanged)
      slider.sendActions(for: .touchUpInside)
      result(nil)
    }
  }
}

func bstreamAudioPresentationController() -> UIViewController? {
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  let window = scenes.filter { $0.activationState == .foregroundActive }
    .flatMap(\.windows).first { $0.isKeyWindow }
  var controller = window?.rootViewController
  while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
    controller = presented
  }
  return controller
}

// A visible public AVRoutePickerView, rather than invoking private selector
// APIs or poking the system's route-picker subview hierarchy.
private final class BStreamSystemAudioPickerController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let title = UILabel()
    title.text = NSLocalizedString("Audio output", comment: "System audio output picker")
    title.font = .preferredFont(forTextStyle: .headline)
    title.textAlignment = .center
    let hint = UILabel()
    hint.text = NSLocalizedString("Choose an audio device", comment: "Tap the AirPlay route picker")
    hint.font = .preferredFont(forTextStyle: .subheadline)
    hint.textAlignment = .center
    hint.numberOfLines = 0
    let routes = AVRoutePickerView()
    routes.prioritizesVideoDevices = false
    routes.translatesAutoresizingMaskIntoConstraints = false
    routes.heightAnchor.constraint(equalToConstant: 72).isActive = true
    let volume = MPVolumeView()
    volume.showsRouteButton = false
    let done = UIButton(type: .system)
    done.setTitle(NSLocalizedString("Done", comment: "Close audio output picker"), for: .normal)
    done.addTarget(self, action: #selector(close), for: .touchUpInside)
    let content = UIStackView(arrangedSubviews: [title, hint, routes, volume, done])
    content.axis = .vertical
    content.spacing = 18
    content.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      content.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      volume.heightAnchor.constraint(equalToConstant: 44),
      done.heightAnchor.constraint(equalToConstant: 44),
    ])
    if #available(iOS 15.0, *) {
      sheetPresentationController?.detents = [.medium()]
      sheetPresentationController?.prefersGrabberVisible = true
    }
  }

  @objc private func close() { dismiss(animated: true) }
}
