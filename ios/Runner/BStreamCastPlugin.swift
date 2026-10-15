import Flutter
import GoogleCast
import UIKit

// Native Cast sender. Registration is cheap; SDK initialization and discovery
// happen only after the user opens the transmission menu.
final class BStreamCastPlugin: NSObject, GCKDiscoveryManagerListener,
  GCKSessionManagerListener, GCKRemoteMediaClientListener, GCKRequestDelegate {
  private let channel: FlutterMethodChannel
  private var context: GCKCastContext?
  private var discoveryRequested = false
  private var sessionSuspended = false
  private weak var observedClient: GCKRemoteMediaClient?
  private var lifecycleObservers: [NSObjectProtocol] = []
  private var progressTimer: Timer?
  private var pendingConnect: FlutterResult?
  private var connectingDeviceId: String?
  private var cancelledConnectingDeviceId: String?
  private var connectTimeout: DispatchWorkItem?
  private var pendingDisconnect: FlutterResult?
  private var disconnectTimeout: DispatchWorkItem?
  private var loadGeneration = 0
  private var loadingContentId: String?
  private var requests: [ObjectIdentifier: PendingRequest] = [:]

  private struct PendingRequest {
    let request: GCKRequest
    let result: FlutterResult
    let generation: Int?
    let timeout: DispatchWorkItem
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "bstream_music/cast", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      self.handle(call, result: result)
    }
  }

  deinit {
    progressTimer?.invalidate()
    connectTimeout?.cancel()
    disconnectTimeout?.cancel()
    observedClient?.remove(self)
    context?.sessionManager.remove(self)
    context?.discoveryManager.remove(self)
    for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
    for pending in requests.values { pending.timeout.cancel(); pending.request.delegate = nil }
  }

  private func initializeIfNeeded() {
    guard context == nil else { return }
    let options = GCKCastOptions(discoveryCriteria:
      GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID))
    options.disableDiscoveryAutostart = true
    options.disableAnalyticsLogging = true
    options.physicalVolumeButtonsWillControlDeviceVolume = true
    if !GCKCastContext.isSharedInstanceInitialized() { GCKCastContext.setSharedInstanceWith(options) }
    let castContext = GCKCastContext.sharedInstance()
    context = castContext
    castContext.discoveryManager.add(self)
    castContext.sessionManager.add(self)
    let center = NotificationCenter.default
    lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
      self?.context?.discoveryManager.stopDiscovery()
      self?.progressTimer?.invalidate()
      self?.progressTimer = nil
    })
    lifecycleObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
      if self.discoveryRequested { self.context?.discoveryManager.startDiscovery() }
      self.observeCurrentClient()
      self.emit()
    })
    observeCurrentClient()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "getState":
      // Merely checking capability must not initiate a network permission
      // prompt, a scan, or restore an unsolicited Cast connection.
      result(state())
    case "startDiscovery":
      initializeIfNeeded()
      discoveryRequested = true
      if UIApplication.shared.applicationState == .active { context?.discoveryManager.startDiscovery() }
      emit()
      result(state())
    case "stopDiscovery":
      discoveryRequested = false
      context?.discoveryManager.stopDiscovery()
      result(nil)
    case "connect":
      initializeIfNeeded()
      connect(arguments["id"] as? String, result: result)
    case "disconnect":
      disconnect(stopPlayback: arguments["stopPlayback"] as? Bool ?? true, result: result)
    case "load":
      load(arguments, result: result)
    case "play", "pause", "stop", "seek":
      guard let client = connectedClient(result: result) else { return }
      let request: GCKRequest
      switch call.method {
      case "play": request = client.play()
      case "pause": request = client.pause()
      case "stop": request = client.stop()
      default:
        guard let position = arguments["positionMs"] as? NSNumber, position.doubleValue.isFinite else {
          result(FlutterError(code: "invalid_position", message: "Invalid seek position", details: nil))
          return
        }
        let options = GCKMediaSeekOptions()
        options.interval = max(0, position.doubleValue / 1000)
        request = client.seek(with: options)
      }
      track(request, result: result)
    case "setVolume":
      guard let session = context?.sessionManager.currentCastSession, session.connectionState == .connected else {
        result(FlutterError(code: "cast_not_connected", message: "No Cast receiver connected", details: nil))
        return
      }
      guard let volume = arguments["volume"] as? NSNumber, volume.doubleValue.isFinite else {
        result(FlutterError(code: "invalid_volume", message: "Invalid volume", details: nil))
        return
      }
      track(session.setDeviceVolume(Float(max(0, min(1, volume.doubleValue)))), result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func state() -> [String: Any] {
    let session = context?.sessionManager.currentCastSession
    let connected = session?.connectionState == .connected
    let client = connected ? session?.remoteMediaClient : nil
    let media = client?.mediaStatus
    var playback = "idle"
    if loadingContentId != nil { playback = "loading" }
    else if let media {
      switch media.playerState {
      case .playing: playback = "playing"
      case .paused: playback = "paused"
      case .buffering, .loading: playback = "loading"
      case .idle: playback = media.idleReason == .finished ? "completed" : "idle"
      default: break
      }
    }
    var devices: [[String: Any]] = []
    if let manager = context?.discoveryManager {
      for index in 0..<manager.deviceCount {
        let device = manager.device(at: index)
        devices.append([
          "id": device.uniqueID, "name": device.friendlyName ?? device.modelName ?? "Google Cast",
          "address": device.networkAddress.ipAddress ?? "", "type": "cast",
        ])
      }
    }
    let customData = media?.mediaInformation?.customData as? [String: Any]
    let contentId = loadingContentId ?? customData?["bstreamContentId"] as? String ?? ""
    let position = loadingContentId == nil ? client?.approximateStreamPosition() ?? 0 : 0
    let duration = media?.mediaInformation?.streamDuration ?? 0
    var output: [String: Any] = [
      "supported": true, "devices": devices, "connected": connected, "suspended": sessionSuspended,
      "deviceId": session?.device.uniqueID ?? "", "deviceName": session?.device.friendlyName ?? "",
      "state": playback, "positionMs": milliseconds(position), "durationMs": milliseconds(duration),
      "volume": Double(session?.currentDeviceVolume ?? 1), "contentId": contentId,
    ]
    if media?.playerState == .idle, media?.idleReason == .error {
      output["error"] = "The receiver could not play this audio format."
    }
    return output
  }

  private func milliseconds(_ seconds: TimeInterval) -> Int64 {
    guard seconds.isFinite else { return 0 }
    return Int64(min(max(0, seconds), Double(Int64.max / 2000)) * 1000)
  }

  private func emit(error: String? = nil) {
    var output = state()
    if let error { output["error"] = error }
    channel.invokeMethod("castState", arguments: output)
    updateProgressTimer()
  }

  private func connectedClient(result: FlutterResult) -> GCKRemoteMediaClient? {
    guard let session = context?.sessionManager.currentCastSession,
          session.connectionState == .connected, let client = session.remoteMediaClient else {
      result(FlutterError(code: "cast_not_connected", message: "No Cast receiver connected", details: nil))
      return nil
    }
    return client
  }

  private func connect(_ deviceId: String?, result: @escaping FlutterResult) {
    guard let deviceId, let manager = context?.sessionManager,
          let device = context?.discoveryManager.device(withUniqueID: deviceId) else {
      result(FlutterError(code: "cast_device_missing", message: "Receiver is no longer available", details: nil))
      return
    }
    if manager.currentCastSession?.connectionState == .connected {
      if manager.currentCastSession?.device.uniqueID == deviceId { result(state()) }
      else { result(FlutterError(code: "cast_busy", message: "Disconnect the current receiver first", details: nil)) }
      return
    }
    if pendingConnect != nil {
      result(FlutterError(code: "cast_busy", message: "A receiver connection is already in progress", details: nil))
      return
    }
    pendingConnect = result
    connectingDeviceId = deviceId
    cancelledConnectingDeviceId = nil
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, self.connectingDeviceId == deviceId else { return }
      self.cancelledConnectingDeviceId = deviceId
      self.completeConnection(error: FlutterError(code: "cast_timeout", message: "Receiver did not respond", details: nil))
      self.context?.sessionManager.endSessionAndStopCasting(true)
    }
    connectTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
    guard manager.startSession(with: device) else {
      completeConnection(error: FlutterError(code: "cast_connection_failed", message: "Cannot connect to receiver", details: nil))
      return
    }
  }

  private func completeConnection(error: FlutterError? = nil) {
    connectTimeout?.cancel()
    connectTimeout = nil
    connectingDeviceId = nil
    let result = pendingConnect
    pendingConnect = nil
    if let error { result?(error) } else { result?(state()) }
  }

  private func disconnect(stopPlayback: Bool, result: @escaping FlutterResult) {
    cancelledConnectingDeviceId = connectingDeviceId
    completeConnection(error: FlutterError(code: "cast_cancelled", message: "Connection cancelled", details: nil))
    cancelRequests(message: "Transmission disconnected")
    loadingContentId = nil
    guard let manager = context?.sessionManager, manager.currentCastSession != nil else {
      result(nil)
      return
    }
    guard pendingDisconnect == nil else {
      result(FlutterError(code: "cast_busy", message: "Disconnect is already in progress", details: nil))
      return
    }
    pendingDisconnect = result
    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let callback = self.pendingDisconnect
      self.pendingDisconnect = nil
      callback?(FlutterError(code: "cast_timeout", message: "Receiver did not disconnect", details: nil))
    }
    disconnectTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    if !manager.endSessionAndStopCasting(stopPlayback) {
      timeout.cancel()
      disconnectTimeout = nil
      pendingDisconnect = nil
      result(FlutterError(code: "cast_disconnect_failed", message: "Cannot disconnect receiver", details: nil))
    }
  }

  private func load(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard let client = connectedClient(result: result) else { return }
    guard let rawUrl = arguments["url"] as? String, let url = URL(string: rawUrl),
          let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          url.host != nil, let contentId = arguments["contentId"] as? String, !contentId.isEmpty else {
      result(FlutterError(code: "cast_invalid_media", message: "Receiver needs an accessible HTTP audio URL", details: nil))
      return
    }
    loadGeneration += 1
    cancelRequests(loadsOnly: true, message: "A newer song replaced this load")
    let metadata = GCKMediaMetadata(metadataType: .musicTrack)
    metadata.setString(arguments["title"] as? String ?? "", forKey: kGCKMetadataKeyTitle)
    metadata.setString(arguments["artist"] as? String ?? "", forKey: kGCKMetadataKeyArtist)
    if let rawArtwork = arguments["artworkUrl"] as? String, let artwork = URL(string: rawArtwork),
       ["http", "https"].contains(artwork.scheme?.lowercased() ?? "") {
      metadata.addImage(GCKImage(url: artwork, width: 320, height: 320))
    }
    let information = GCKMediaInformationBuilder(contentURL: url)
    information.streamType = .buffered
    information.contentType = arguments["mimeType"] as? String ?? "audio/mp4"
    information.metadata = metadata
    information.customData = ["bstreamContentId": contentId]
    if let milliseconds = arguments["durationMs"] as? NSNumber, milliseconds.doubleValue.isFinite {
      information.streamDuration = max(0, milliseconds.doubleValue / 1000)
    }
    let requestData = GCKMediaLoadRequestDataBuilder()
    requestData.mediaInformation = information.build()
    requestData.autoplay = NSNumber(value: arguments["autoplay"] as? Bool ?? true)
    if let milliseconds = arguments["positionMs"] as? NSNumber, milliseconds.doubleValue.isFinite {
      requestData.startTime = max(0, milliseconds.doubleValue / 1000)
    }
    loadingContentId = contentId
    track(client.loadMedia(with: requestData.build()), result: result, generation: loadGeneration)
    emit()
  }

  private func track(_ request: GCKRequest, result: @escaping FlutterResult, generation: Int? = nil) {
    let key = ObjectIdentifier(request)
    let timeout = DispatchWorkItem { [weak self] in
      self?.finishRequest(key, error: FlutterError(code: "cast_timeout", message: "Receiver did not acknowledge request", details: nil))
    }
    requests[key] = PendingRequest(request: request, result: result, generation: generation, timeout: timeout)
    request.delegate = self
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    if !request.inProgress {
      if let error = request.error {
        finishRequest(key, error: FlutterError(code: "cast_request_failed", message: error.localizedDescription, details: nil))
      } else { finishRequest(key) }
    }
  }

  private func finishRequest(_ key: ObjectIdentifier, error: FlutterError? = nil) {
    guard let pending = requests.removeValue(forKey: key) else { return }
    pending.timeout.cancel()
    pending.request.delegate = nil
    if let generation = pending.generation {
      guard generation == loadGeneration else {
        pending.result(FlutterError(code: "cast_cancelled", message: "Song was replaced", details: nil))
        return
      }
      let statusData = observedClient?.mediaStatus?.mediaInformation?.customData as? [String: Any]
      if error != nil || statusData?["bstreamContentId"] as? String == loadingContentId {
        loadingContentId = nil
      }
    }
    if let error { pending.result(error); emit(error: error.message) }
    else { pending.result(state()); emit() }
  }

  private func cancelRequests(loadsOnly: Bool = false, message: String) {
    let keys = requests.compactMap { key, pending in !loadsOnly || pending.generation != nil ? key : nil }
    for key in keys {
      guard let pending = requests.removeValue(forKey: key) else { continue }
      pending.timeout.cancel()
      pending.request.delegate = nil
      pending.request.cancel()
      pending.result(FlutterError(code: "cast_cancelled", message: message, details: nil))
    }
  }

  private func observeCurrentClient() {
    let client = context?.sessionManager.currentCastSession?.remoteMediaClient
    if observedClient !== client {
      observedClient?.remove(self)
      observedClient = client
      client?.add(self)
    }
    updateProgressTimer()
  }

  private func updateProgressTimer() {
    let shouldRun = UIApplication.shared.applicationState == .active
      && context?.sessionManager.currentCastSession?.connectionState == .connected
      && observedClient?.mediaStatus?.playerState == .playing
    if shouldRun, progressTimer == nil {
      progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.emit() }
      progressTimer?.tolerance = 0.2
    } else if !shouldRun {
      progressTimer?.invalidate()
      progressTimer = nil
    }
  }

  func didUpdateDeviceList() { if discoveryRequested { emit() } }

  func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
    sessionSuspended = false
    guard let cast = session as? GCKCastSession else { return }
    if cast.device.uniqueID == cancelledConnectingDeviceId {
      sessionManager.endSessionAndStopCasting(true)
      return
    }
    observeCurrentClient()
    if cast.device.uniqueID == connectingDeviceId { completeConnection() }
    emit()
  }

  func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
    sessionSuspended = false
    observeCurrentClient()
    emit()
  }

  func sessionManager(_ sessionManager: GCKSessionManager, session: GCKSession,
                      didReceiveDeviceVolume volume: Float, muted: Bool) {
    guard session === context?.sessionManager.currentCastSession else { return }
    emit()
  }

  func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
    guard session.device.uniqueID == connectingDeviceId else { return }
    completeConnection(error: FlutterError(code: "cast_connection_failed", message: error.localizedDescription, details: nil))
    emit(error: error.localizedDescription)
  }

  func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
    if let current = context?.sessionManager.currentCastSession, current !== session { return }
    sessionSuspended = false
    observedClient?.remove(self)
    observedClient = nil
    loadingContentId = nil
    cancelRequests(message: "Transmission ended")
    disconnectTimeout?.cancel()
    disconnectTimeout = nil
    let result = pendingDisconnect
    pendingDisconnect = nil
    result?(nil)
    emit(error: error?.localizedDescription)
  }

  func sessionManager(_ sessionManager: GCKSessionManager, didSuspend session: GCKSession,
                      with reason: GCKConnectionSuspendReason) {
    guard session === context?.sessionManager.currentCastSession else { return }
    sessionSuspended = true
    progressTimer?.invalidate()
    progressTimer = nil
    // Suspension is not a completed song or a deliberate disconnect. Cast
    // can reconnect when the sender returns to the foreground.
    emit()
  }

  func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
    guard client === observedClient else { return }
    let customData = mediaStatus?.mediaInformation?.customData as? [String: Any]
    if loadingContentId != nil, customData?["bstreamContentId"] as? String == loadingContentId {
      loadingContentId = nil
    }
    emit()
  }

  func requestDidComplete(_ request: GCKRequest) { finishRequest(ObjectIdentifier(request)) }
  func request(_ request: GCKRequest, didFailWithError error: GCKError) {
    finishRequest(ObjectIdentifier(request), error:
      FlutterError(code: "cast_request_failed", message: error.localizedDescription, details: nil))
  }
  func request(_ request: GCKRequest, didAbortWith reason: GCKRequestAbortReason) {
    finishRequest(ObjectIdentifier(request), error:
      FlutterError(code: "cast_cancelled", message: "Receiver request was cancelled", details: nil))
  }
}
