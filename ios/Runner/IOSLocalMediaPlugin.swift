import Flutter
import MediaPlayer
import UIKit

/// Exposes the locally playable portion of the user's iOS Media Library.
///
/// Subscription/DRM items and cloud-only items don't provide a URL that
/// AVPlayer can consume, so they are deliberately omitted from the catalog.
final class IOSLocalMediaPlugin {
  private let worker = DispatchQueue(
    label: "com.bstream.bstreamMusic.local-media",
    qos: .userInitiated
  )
  private var itemsByURL: [String: MPMediaItem] = [:]

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "permissionStatus":
      result(Self.permissionName(MPMediaLibrary.authorizationStatus()))
    case "requestPermission":
      requestPermission(result: result)
    case "queryTracks":
      queryTracks(result: result)
    case "loadArtwork":
      loadArtwork(arguments: call.arguments, result: result)
    case "openPermissionSettings":
      openPermissionSettings(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestPermission(result: @escaping FlutterResult) {
    MPMediaLibrary.requestAuthorization { status in
      DispatchQueue.main.async {
        result(Self.permissionName(status))
      }
    }
  }

  private func openPermissionSettings(result: @escaping FlutterResult) {
    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.open(settingsURL, options: [:]) { opened in
        result(opened)
      }
    }
  }

  private func queryTracks(result: @escaping FlutterResult) {
    guard MPMediaLibrary.authorizationStatus() == .authorized else {
      worker.async { [weak self] in
        self?.itemsByURL.removeAll(keepingCapacity: false)
      }
      result([Any]())
      return
    }

    worker.async { [weak self] in
      guard let self else { return }
      guard MPMediaLibrary.authorizationStatus() == .authorized else {
        self.itemsByURL.removeAll(keepingCapacity: false)
        DispatchQueue.main.async { result([Any]()) }
        return
      }
      let items = MPMediaQuery.songs().items ?? []
      var nextItemsByURL: [String: MPMediaItem] = [:]
      var tracks: [[String: Any]] = []
      tracks.reserveCapacity(items.count)

      for item in items {
        guard !item.hasProtectedAsset, let assetURL = item.assetURL else {
          continue
        }

        let uri = assetURL.absoluteString
        nextItemsByURL[uri] = item
        tracks.append(Self.trackPayload(for: item, uri: uri))
      }
      guard MPMediaLibrary.authorizationStatus() == .authorized else {
        self.itemsByURL.removeAll(keepingCapacity: false)
        DispatchQueue.main.async { result([Any]()) }
        return
      }
      self.itemsByURL = nextItemsByURL

      DispatchQueue.main.async {
        result(tracks)
      }
    }
  }

  private func loadArtwork(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let arguments = arguments as? [String: Any],
      let audioURI = arguments["audioUri"] as? String,
      !audioURI.isEmpty
    else {
      result(
        FlutterError(
          code: "invalid-arguments",
          message: "audioUri is required.",
          details: nil
        )
      )
      return
    }

    let requestedWidth = arguments["targetWidth"] as? Int ?? 320
    let width = CGFloat(min(max(requestedWidth, 32), 1280))

    worker.async { [weak self] in
      guard let self else { return }
      guard MPMediaLibrary.authorizationStatus() == .authorized else {
        self.itemsByURL.removeAll(keepingCapacity: false)
        DispatchQueue.main.async { result(nil) }
        return
      }
      let item = self.itemsByURL[audioURI] ?? self.findItem(withURL: audioURI)
      guard
        let image = item?.artwork?.image(at: CGSize(width: width, height: width)),
        let bytes = Self.boundedPNGData(
          for: image,
          maximumDimension: width
        )
      else {
        DispatchQueue.main.async { result(nil) }
        return
      }

      DispatchQueue.main.async {
        result(FlutterStandardTypedData(bytes: bytes))
      }
    }
  }

  private func findItem(withURL requestedURL: String) -> MPMediaItem? {
    guard MPMediaLibrary.authorizationStatus() == .authorized else {
      return nil
    }
    let item = MPMediaQuery.songs().items?.first {
      !$0.hasProtectedAsset && $0.assetURL?.absoluteString == requestedURL
    }
    if let item {
      itemsByURL[requestedURL] = item
    }
    return item
  }

  private static func trackPayload(
    for item: MPMediaItem,
    uri: String
  ) -> [String: Any] {
    let title = normalized(item.title) ?? "Audio"
    let durationMilliseconds = item.playbackDuration > 0
      ? Int((item.playbackDuration * 1000).rounded())
      : 0

    var payload: [String: Any] = [
      "id": "ios-media:\(item.persistentID)",
      "uri": uri,
      "displayName": title,
      "title": title,
      "durationMs": durationMilliseconds,
      "mimeType": mimeType(for: item.assetURL),
      "folderId": "ios-media-library",
      "folderName": "Biblioteca",
    ]
    if let artist = normalized(item.artist) {
      payload["artist"] = artist
    }
    if let album = normalized(item.albumTitle) {
      payload["album"] = album
    }
    return payload
  }

  private static func permissionName(
    _ status: MPMediaLibraryAuthorizationStatus
  ) -> String {
    switch status {
    case .authorized:
      return "granted"
    case .notDetermined:
      return "notDetermined"
    case .denied:
      return "permanentlyDenied"
    case .restricted:
      return "restricted"
    @unknown default:
      return "denied"
    }
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  /// Encodes at most the requested number of pixels on the longest edge.
  ///
  /// `MPMediaItemArtwork.image(at:)` can return an available rendition larger
  /// than the requested point size, so its result still needs an explicit
  /// pixel-size bound before crossing the method channel.
  private static func boundedPNGData(
    for image: UIImage,
    maximumDimension: CGFloat
  ) -> Data? {
    let pixelWidth = image.size.width * image.scale
    let pixelHeight = image.size.height * image.scale
    let largestDimension = max(pixelWidth, pixelHeight)
    guard largestDimension > 0 else { return nil }
    guard largestDimension > maximumDimension else {
      return image.pngData()
    }

    let resizeScale = maximumDimension / largestDimension
    let outputSize = CGSize(
      width: max(1, floor(pixelWidth * resizeScale)),
      height: max(1, floor(pixelHeight * resizeScale))
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let resized = UIGraphicsImageRenderer(
      size: outputSize,
      format: format
    ).image { _ in
      image.draw(in: CGRect(origin: .zero, size: outputSize))
    }
    return resized.pngData()
  }

  private static func mimeType(for url: URL?) -> String {
    switch url?.pathExtension.lowercased() {
    case "mp3":
      return "audio/mpeg"
    case "wav":
      return "audio/wav"
    case "aif", "aiff":
      return "audio/aiff"
    case "caf":
      return "audio/x-caf"
    default:
      return "audio/mp4"
    }
  }
}
