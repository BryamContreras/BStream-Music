import AVFoundation
import AudioToolbox
import Flutter
import Foundation

/// Reads encoded source properties once without opening another player or
/// asking AVAudioSession for the device's unrelated output sample rate.
final class IOSLocalAudioQualityPlugin {
  private let channel: FlutterMethodChannel
  private let reader = IOSLocalAudioQualityReader()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "bstream/local_audio_quality", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "read" else { result(FlutterMethodNotImplemented); return }
      guard let self,
            let arguments = call.arguments as? [String: Any],
            let source = arguments["source"] as? String else { result(nil); return }
      self.reader.read(source: source) { result($0) }
    }
  }

  func dispose() {
    channel.setMethodCallHandler(nil)
    reader.dispose()
  }

  deinit { dispose() }
}

/// Serial, bounded work. Asset I/O uses AVFoundation's asynchronous loading,
/// and every result crosses back to Flutter on the main queue only once.
final class IOSLocalAudioQualityReader {
  private struct Request {
    let url: URL
    let completion: ([String: Any]?) -> Void
  }

  private final class Session {
    let request: Request
    let asset: AVURLAsset
    let securityScoped: Bool
    var timeout: DispatchWorkItem?
    var finished = false
    private let closeLock = NSLock()
    private var closed = false

    init(request: Request) {
      self.request = request
      securityScoped = request.url.isFileURL && request.url.startAccessingSecurityScopedResource()
      asset = AVURLAsset(url: request.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
    }

    func close() {
      closeLock.lock()
      let needsClose = !closed
      closed = true
      closeLock.unlock()
      guard needsClose else { return }
      timeout?.cancel()
      timeout = nil
      asset.cancelLoading()
      if securityScoped { request.url.stopAccessingSecurityScopedResource() }
    }

    deinit { close() }
  }

  private let worker = DispatchQueue(label: "com.bstream.bstreamMusic.local-audio-quality", qos: .utility)
  private var pending: [Request] = []
  private var active: Session?
  private var disposed = false

  func read(source: String, completion: @escaping ([String: Any]?) -> Void) {
    guard let url = Self.localURL(source) else {
      DispatchQueue.main.async { completion(nil) }
      return
    }
    worker.async {
      guard !self.disposed, self.pending.count < 8 else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      self.pending.append(Request(url: url, completion: completion))
      self.startNext()
    }
  }

  func dispose() {
    worker.async {
      guard !self.disposed else { return }
      self.disposed = true
      if let active = self.active { self.finish(active, payload: nil) }
      let abandoned = self.pending
      self.pending.removeAll()
      for request in abandoned {
        DispatchQueue.main.async { request.completion(nil) }
      }
    }
  }

  private func startNext() {
    guard !disposed, active == nil, !pending.isEmpty else { return }
    let session = Session(request: pending.removeFirst())
    active = session
    let timeout = DispatchWorkItem { [weak self] in self?.finish(session, payload: nil) }
    session.timeout = timeout
    worker.asyncAfter(deadline: .now() + 5, execute: timeout)

    if #available(iOS 15.0, *) {
      Task { [weak self] in
        do {
          let tracks = try await session.asset.loadTracks(withMediaType: .audio)
          guard Self.canDescribeAudioTrack(tracks.count), let track = tracks.first else {
            self?.complete(session, payload: nil)
            return
          }
          let descriptions = try await track.load(.formatDescriptions)
          let bitrate = (try? await track.load(.estimatedDataRate)) ?? 0
          self?.complete(session, payload: Self.payload(descriptions: descriptions, bitrate: bitrate))
        } catch {
          self?.complete(session, payload: nil)
        }
      }
    } else {
      // iOS 13/14 retain the asynchronous KVO-loading API. Property reads below
      // run on our worker only after each required key reports .loaded.
      session.asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self] in
        guard let self else { return }
        self.worker.async {
          guard self.active === session, !session.finished else { return }
          guard session.asset.statusOfValue(forKey: "tracks", error: nil) == .loaded else {
            self.finish(session, payload: nil)
            return
          }
          let tracks = session.asset.tracks(withMediaType: .audio)
          guard Self.canDescribeAudioTrack(tracks.count), let track = tracks.first else {
            self.finish(session, payload: nil)
            return
          }
          track.loadValuesAsynchronously(forKeys: ["formatDescriptions", "estimatedDataRate"]) { [weak self] in
            guard let self else { return }
            self.worker.async {
              guard self.active === session, !session.finished else { return }
              guard track.statusOfValue(forKey: "formatDescriptions", error: nil) == .loaded else {
                self.finish(session, payload: nil)
                return
              }
              let descriptions = track.formatDescriptions as? [CMFormatDescription] ?? []
              let bitrate = track.statusOfValue(forKey: "estimatedDataRate", error: nil) == .loaded
                ? track.estimatedDataRate : 0
              self.finish(session, payload: Self.payload(descriptions: descriptions, bitrate: bitrate))
            }
          }
        }
      }
    }
  }

  private func complete(_ session: Session, payload: [String: Any]?) {
    worker.async { self.finish(session, payload: payload) }
  }

  private func finish(_ session: Session, payload: [String: Any]?) {
    guard active === session, !session.finished else { return }
    session.finished = true
    session.close()
    active = nil
    DispatchQueue.main.async { session.request.completion(payload) }
    startNext()
  }

  static func localURL(_ source: String) -> URL? {
    let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains("\0") else { return nil }
    if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
    guard let url = URL(string: value) else { return nil }
    switch url.scheme?.lowercased() {
    case "file":
      guard (url.host?.isEmpty ?? true) || url.host?.lowercased() == "localhost",
            url.path.hasPrefix("/"), url.query == nil, url.fragment == nil else { return nil }
      return url
    case "ipod-library":
      // Existing, permission-granted MPMediaItem.assetURL values are local.
      guard !(url.host?.isEmpty ?? true) else { return nil }
      return url
    default:
      return nil
    }
  }

  static func payload(descriptions: [CMFormatDescription], bitrate: Float) -> [String: Any]? {
    guard let description = descriptions.first(where: {
      CMFormatDescriptionGetMediaType($0) == kCMMediaType_Audio
    }), let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
    var result: [String: Any] = [:]
    if let format = formatName(basic.mFormatID) {
      result["codec"] = format.codec
      result["mimeType"] = format.mime
    }
    if let sampleRate = positiveInt(basic.mSampleRate) { result["sampleRate"] = sampleRate }
    if basic.mChannelsPerFrame > 0 { result["channels"] = Int(basic.mChannelsPerFrame) }
    // AVAssetTrack's estimate describes this encoded audio track. Do not use
    // file size/duration or AVAudioFile.processingFormat (decoded PCM).
    if let bitsPerSecond = positiveInt(Double(bitrate)) {
      result["bitrate"] = bitsPerSecond
    } else if basic.mFormatID == kAudioFormatLinearPCM, basic.mBytesPerFrame > 0 {
      // Only an original uncompressed PCM description has a fixed byte rate.
      // A compressed stream's decoded/output PCM settings must never be used.
      let planes = basic.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        ? 1 : basic.mChannelsPerFrame
      if let fixedBitrate = positiveInt(
        Double(basic.mBytesPerFrame) * Double(planes) * basic.mSampleRate * 8
      ) { result["bitrate"] = fixedBitrate }
    }
    return result.isEmpty ? nil : result
  }

  // Playback may select an alternate language/track. Reporting the first one
  // would be a guess until the backend shares its selected track identifier.
  static func canDescribeAudioTrack(_ count: Int) -> Bool { count == 1 }

  static func formatName(_ format: AudioFormatID) -> (codec: String, mime: String)? {
    switch format {
    case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
         kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
      return ("AAC", "audio/aac")
    case kAudioFormatMPEGLayer3: return ("MP3", "audio/mpeg")
    case kAudioFormatOpus: return ("Opus", "audio/opus")
    case kAudioFormatFLAC: return ("FLAC", "audio/flac")
    case kAudioFormatAppleLossless: return ("ALAC", "audio/alac")
    case kAudioFormatLinearPCM: return ("PCM", "audio/raw")
    case kAudioFormatAC3: return ("AC-3", "audio/ac3")
    case kAudioFormatEnhancedAC3: return ("E-AC-3", "audio/eac3")
    default: return nil
    }
  }

  private static func positiveInt(_ value: Double) -> Int? {
    guard value.isFinite, value > 0, let result = Int(exactly: value.rounded()), result > 0 else { return nil }
    return result
  }

  deinit { active?.close() }
}
